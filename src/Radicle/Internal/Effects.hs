{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UndecidableInstances #-}

module Radicle.Internal.Effects where

import           Protolude hiding (TypeError, toList)

import qualified Data.Map as Map
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc (pretty)
import           Data.Text.Prettyprint.Doc.Render.Terminal (putDoc)
import System.Console.Haskeline
import           GHC.Exts (IsList(..))

import           Radicle.Internal.Core
import           Radicle.Internal.Crypto
import           Radicle.Internal.Doc (md)
import           Radicle.Internal.Effects.Capabilities
import           Radicle.Internal.Interpret
import           Radicle.Internal.Pretty
import           Radicle.Internal.PrimFns
import qualified Radicle.Internal.UUID as UUID


type ReplM m =
    ( Monad m, Stdout (Lang m), Stdin (Lang m)
    , MonadRandom m, UUID.MonadUUID m
    , MonadState [Text] m
    , ReadFile (Lang m)
    , GetEnv (Lang m) Value
    , SetEnv (Lang m) Value )

instance MonadRandom (InputT IO) where
    getRandomBytes = liftIO . getRandomBytes
instance MonadRandom (InputT (StateT [Text] IO)) where
    getRandomBytes = liftIO . getRandomBytes
instance MonadRandom m => MonadRandom (LangT (Bindings (PrimFns m)) m) where
    getRandomBytes = lift . getRandomBytes

instance UUID.MonadUUID (InputT IO) where
    uuid = liftIO UUID.uuid
instance UUID.MonadUUID (InputT (StateT [Text] IO)) where
    uuid = liftIO UUID.uuid
instance UUID.MonadUUID m => UUID.MonadUUID (LangT (Bindings (PrimFns m)) m) where
    uuid = lift UUID.uuid

instance MonadState r m => MonadState r (InputT m) where
    state s = lift $ state s

repl :: Maybe FilePath -> Text -> Text -> Bindings (PrimFns (InputT (StateT [Text] IO))) -> IO ()
repl histFile preFileName preCode bindings = do
    let settings = setComplete completion $ defaultSettings { historyFile = histFile }
    r <- evalStateT (runInputT settings
        $ fmap fst $ runLang bindings
        $ void $ interpretMany preFileName preCode) []
    case r of
        Left (LangError _ Exit) -> pure ()
        Left e                  -> putDoc $ pretty e
        Right ()                -> pure ()

-- Not sure why this instance isn't being picked up from haskeline
instance MonadException m => MonadException (StateT s m) where
    controlIO f = StateT $ \s -> controlIO $ \(RunIO run) -> let
                    run' = RunIO (fmap (StateT . const) . run . flip runStateT s)
                    in fmap (flip runStateT s) $ f run'

completion :: CompletionFunc (StateT [Text] IO)
completion = completeWord Nothing ['(', ')', ' ', '\n'] go
  where
    -- Any type for first param will do
    bnds :: Bindings (PrimFns (InputT (StateT [Text] IO)))
    bnds = replBindings
    go :: [Char] -> StateT [Text] IO [Completion]
    go s = fmap simpleCompletion
         . filter (toS s `isPrefixOf`)
         . fmap toS
         <$> get

replBindings :: ReplM m => Bindings (PrimFns m)
replBindings = addPrimFns replPrimFns pureEnv

replPrimFns :: ReplM m => PrimFns m
replPrimFns = fromList $ allDocs $
    [ ( "put-str!"
      , [md|Outputs a string verbatim.|]
      , oneArg "put-str!" $ \case
          String str -> putStrS str >> pure nil
          _ -> throwErrorHere $ TypeError "put-str!: expects a string"
      )

    , ( "doc!"
      , [md|Prints the documentation attached to a value and returns `()`. To retreive
           the docstring as a value use `doc` instead.|]
      , oneArg "doc!" $ \case
          Atom i -> do
            d <- lookupAtomDoc i
            putStrS $ fromMaybe "No docs." d
            pure nil
          _ -> throwErrorHere $ TypeError "doc!: expects an atom"
      )

    , ( "apropos!"
      , [md|Prints documentation for all documented variables in scope.|]
      , \case
          [] -> do
            env <- gets bindingsEnv
            let docs = [ i <> "\n" <> doc | (Ident i, Just doc, _) <- toList env ]
            putStrS (T.intercalate "\n\n" docs)
            pure nil
          xs -> throwErrorHere $ WrongNumberOfArgs "apropos!" 0 (length xs)
      )

    , ( "set-env!"
      , [md|Given an atom `x` and a value `v`, sets the value associated to `x` in
           the current environemtn to be `v`. Doesn't evaluate `v`.|]
      , \case
        [Atom x, v] -> do
            defineAtom x Nothing v
            pure nil
        [_, _] -> throwErrorHere $ TypeError "Expected atom as first arg"
        xs  -> throwErrorHere $ WrongNumberOfArgs "set-env!" 2 (length xs))

    , ( "get-line!"
      , [md|Reads a single line of input and returns it as a string.|]
      , \case
          [] -> maybe nil toRad <$> getLineS
          [env] -> do
              e' :: Bindings () <- case fromRad env of
                  Right v -> pure v
                  Left _ -> throwErrorHere $ OtherError "get-line!"
              lift $ put $ fmap fromIdent $ Map.keys $ fromEnv $ bindingsEnv e'
              maybe nil toRad <$> getLineS
          xs -> throwErrorHere $ WrongNumberOfArgs "get-line!" 0 (length xs)
      )

    , ("subscribe-to!"
      , [md|Expects a dict `s` (representing a subscription) and a function `f`. The dict
           `s` should have a function `getter` at the key `:getter`. This function is called
           repeatedly (with no arguments), its result is then evaluated and passed to `f`.|]
      , \case
        [x, v] -> do
            e <- gets bindingsEnv
            case (x, v) of
                (Dict m, fn) -> case Map.lookup (Keyword $ unsafeToIdent "getter") m of
                    Nothing -> throwErrorHere
                        $ OtherError "subscribe-to!: Expected ':getter' key"
                    Just g -> loop go
                      where
                        loop action = do
                            st <- get
                            join $ (action >> pure (loop action)) `catchError`
                                (\err -> case err of
                                   LangError _ Exit -> pure (pure nil)
                                   LangError _ (Impossible _) -> do
                                       putStrS (renderPrettyDef err)
                                       throwError err
                                   _ -> do
                                       putStrS (renderPrettyDef err)
                                       put st
                                       pure (loop action))
                        go = do
                            -- We need to evaluate the getter in the original
                            -- environment in which it was defined, but the
                            -- /result/ of the getter is then evaluated in the
                            -- current environment.
                            line <- eval =<< (g $$ [])
                            -- Similarly, the application of the subscriber
                            -- function is evaluated in the original
                            -- environment.
                            void $ withEnv (const e) (fn $$ [quote line])
                _  -> throwErrorHere $ TypeError "subscribe-to!: Expected dict"
        xs  -> throwErrorHere $ WrongNumberOfArgs "subscribe-to!" 2 (length xs))

    , ( "read-file!"
      , [md|Reads the contents of a file and returns it as a string.|]
      , oneArg "read-file!" $ \case
          String filename -> String <$> readFileS filename
          _ -> throwErrorHere $ TypeError "read-file!: expects a string"
      )
    , ( "load!"
      , [md|Evaluates the contents of a file. Each seperate radicle expression is
           `eval`uated according to the current definition of `eval`.|]
      , oneArg "load!" $ \case
          String filename -> readFileS filename >>= interpretMany ("[load! " <> filename <> "]")
          _ -> throwErrorHere $ TypeError "load!: expects a string"
      )
    , ( "gen-key-pair!"
      , [md|Given an elliptic curve, generates a cryptographic key-pair. Use
           `default-ecc-curve` for a default value for the elliptic curve.|]
      , \case
          [curvev] -> do
            curve <- hoistEither . first (toLangError . OtherError) $ fromRad curvev
            (pk, sk) <- generateKeyPair curve
            let pkv = toRad pk
            let skv = toRad sk
            pure . Dict . Map.fromList $
              [ (Keyword (Ident "private-key"), skv)
              , (Keyword (Ident "public-key"), pkv)
              ]
          xs -> throwErrorHere $ WrongNumberOfArgs "gen-key-pair!" 0 (length xs)
      )
    , ( "gen-signature!"
      , [md|Given a private key and a message (a string), generates a cryptographic
           signature for the message.|]
      , \case
          [skv, String msg] -> do
            sk <- hoistEither . first (toLangError . OtherError) $ fromRad skv
            toRad <$> signText sk msg
          _ -> throwErrorHere $ TypeError "gen-signature!: expects a string."
      )
    , ( "uuid!"
      , [md|Generates a random UUID.|]
      , \case
          [] -> String <$> UUID.uuid
          xs -> throwErrorHere $ WrongNumberOfArgs "uuid!" 0 (length xs)
      )
    , ( "exit!"
      , [md|Exit the interpreter immediately.|]
      , \case
          [] -> throwErrorHere Exit
          xs -> throwErrorHere $ WrongNumberOfArgs "exit!" 0 (length xs)
      )
    ]

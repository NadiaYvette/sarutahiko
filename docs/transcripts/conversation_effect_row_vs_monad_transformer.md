# Conversation: Effect Rows + Extensible Records vs Monad Transformer Stacks

## User Question 1
What is the "design pattern" for parsing using row types for extensible records and algebraic effects?

## Assistant Answer
The “design pattern” is to **define a parser as an effectful computation whose state and configuration live in an extensible row‑typed record**.

1. **Extensible record** – Use a large‑anon/large‑records row (`r`) to hold whatever the parser needs (input buffer, position, error accumulation, user‑defined hooks, etc.). The row is open, so additional fields can be added later without changing existing parser code.

2. **Algebraic effects** – Model parsing operations (e.g., `satisfy`, `lookAhead`, `commit`, `fail`) as effect signatures in an effect row (`e`). The interpreter for the effect row provides the actual implementation (state updates, backtracking, error handling).

3. **Composition** – Parser combinators are built by sequencing effectful actions (`do`‑notation or `bind`) that read/write the record row and invoke the effect row. Because both the record and effect rows are polymorphic, the same combinator works for any concrete record/effect instantiation (e.g., adding a new “trace” field or a new “memoisation” effect).

4. **Interpretation** – To run a parser, supply a concrete record (initial input, position = 0, etc.) and an effect handler (e.g., a state‑plus‑error handler). The handler interprets the effect row, updates the record, and returns either a successful result with the final record or an error.

**In short:**  
`Parser r e a = Eff e (Rec r) a` – a computation in an effect row `e` that reads and writes an extensible record `r`. Parsers are built by combining primitive effectful actions; different parsers reuse the same primitives by varying only the concrete record/effect rows they are instantiated with. This gives extensible, reusable, and type‑safe parsers using row‑typed records and algebraic effects.

## User Question 2
What are the software engineering reasons why effects and extensible records are supposed to mix well?

## Assistant Answer
Effects and extensible records complement each other because they give orthogonal, composable ways to manage state and capabilities:

1. **Local, explicit state** – An extensible record holds all mutable pieces a computation might need (input buffer, position, error log, config, etc.). Because the record is a first‑class value, you can thread it through functions, snapshot it for back‑tracking, or replace it wholesale without hidden globals.

2. **Effect‑row polymorphism** – Algebraic effects let you declare *what* a computation can do (read, write, fail, log, etc.) without committing to *how* it is done. The effect row is open, so new capabilities can be added later and existing code stays unchanged.

3. **Separation of concerns** – The record describes the *data* that flows; the effect row describes the *operations* that can be performed on that data. Changing one (e.g., adding a new field to the record) does not require rewriting effect handlers, and vice‑versa.

4. **Fine‑grained reuse** – A parser built as `Eff e (Rec r) a` can be instantiated with any concrete record `r₀` (e.g., just input+pos) or a richer one (input+pos+user hooks) and any concrete effect handler `e₀` (state‑only, state+error, state+error+trace). The same parser code works in all contexts.

5. **Type‑safe evolution** – Because both rows are tracked by the type system, adding a new field or effect is a *breaking* change only for code that explicitly mentions it; the compiler warns you where the new piece is needed, preventing silent mismatches.

6. **Combinatorial abstraction** – Primitives (satisfy, lookAhead, commit, fail) are tiny effectful actions that read/write the record. Higher‑order combinators (choice, repetition, sequencing) are built by composing those primitives; they automatically inherit whatever record/effects the primitives use.

7. **Easy testing & mocking** – In tests you can supply a record with dummy data and an effect handler that logs or throws, exercising the parser without needing a full runtime environment.

8. **Performance via specialization** – The compiler can specialize the generic `Eff e (Rec r) a` to a concrete monoid/state transformer when `e` and `r` are known, eliminating the overhead of the effect layer while preserving the same source code.

Together, they let you write parsers (or any effectful program) that are **modular, extensible, and type‑safe**, with clear boundaries between data flow and capability flow.

## User Question 3
What's the distinctive appearance of code tackling the awkward squad that uses algebraic effects & extensible records relative to code tackling them by other means? I thought I saw the field names being used and written in some interesting way like with a # prepended to them and the code being shorter somehow, but maybe a pair of equivalent concrete examples of with & without to compare would be informative.

## Assistant Answer
[See detailed comparison with code examples in the transcript.]

### Traditional Way (mtl + ReaderT + Has)

```haskell
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module WorkerTraditional where

import Control.Monad.Reader
import Control.Monad.Catch (MonadMask, MonadCatch, MonadThrow)
import Data.IORef
import System.Process (CreateProcess, ProcessHandle)

data WorkerConfig = WorkerConfig
  { cfgWorkDir :: FilePath
  , cfgMaxTries :: Int
  , cfgLogger   :: String -> IO ()
  }

data WorkerMetrics = WorkerMetrics
  { metAttempts :: Int
  , metFailed   :: Bool
  }

data AppEnv = AppEnv
  { envConfig  :: WorkerConfig
  , envMetrics :: IORef WorkerMetrics
  }

class HasConfig env where configL :: env -> WorkerConfig
class HasMetrics env where metricsL :: env -> IORef WorkerMetrics

instance HasConfig AppEnv where configL = envConfig
instance HasMetrics AppEnv where metricsL = envMetrics

newtype AppM a = AppM { unAppM :: ReaderT AppEnv IO a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader AppEnv,
            MonadThrow, MonadCatch, MonadMask)

runTaskWithRetry :: (MonadReader env m, HasConfig env, HasMetrics env,
                     MonadIO m) => CreateProcess -> m (Either String ())
runTaskWithRetry procSpec = do
  env <- ask
  let cfg = configL env
      metRef = metricsL env
  liftIO $ cfgLogger cfg $ "Spawning task in " <> cfgWorkDir cfg
  liftIO $ modifyIORef' metRef $ \m -> m { metAttempts = metAttempts m + 1 }
  -- … run process, handle result, update metrics on failure, etc.
```

### Effect‑Row + Extensible Record Way

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeOperators #-}

module WorkerEffectful where

import Control.Carrier.Reader
import Control.Carrier.State
import Control.Carrier.Trace
import Control.Effect.Fail
import Control.Effect.Carrier
import Data.Kind (Type)
import Data.Row.Records
import System.Process

type WorkerConfRec =
  '[ "workDir"   := FilePath
   , "maxTries"  := Int
   , "logger"    := (String -> IO ()) ]

type WorkerEffs
  = '[ Reader (Record WorkerConfRec)
     , State (Record '[ "attempts" := Int, "failed" := Bool ])
     , Trace
     , Fail
     , IO
     ]

type WorkerM = Eff WorkerEffs

getWorkDir :: Member (Reader (Record WorkerConfRec)) sig => Eff sig FilePath
getWorkDir = reader (#workDir)

getMaxTries :: Member (Reader (Record WorkerConfRec)) sig => Eff sig Int
getMaxTries = reader (#maxTries)

logInfo :: Member Trace sig => String -> Eff sig ()
logInfo msg = trace msg

incAttempts :: Member (State (Record '[ "attempts" := Int, "failed" := Bool ])) sig => Eff sig ()
incAttempts = modify' $ \s -> s & #attempts +~ 1

markFailed :: Member (State (Record '[ "attempts" := Int, "failed" := Bool ])) sig => Eff sig ()
markFailed = modify' $ \s -> s & #failed .~ True

runProcessIO :: (Member IO sig, Member Fail sig) => CreateProcess -> Eff sig (Either String ExitCode)
runProcessIO spec = do
  result <- tryIO $ waitForProcess =<< createProcess spec
  case result of
    Left e  -> throwError $ show e
    Right c -> pure $ Right c

runTaskWithRetryEff :: ( Member (Reader (Record WorkerConfRec)) sig
                       , Member (State (Record '[ "attempts" := Int, "failed" := Bool ])) sig
                       , Member Trace sig
                       , Member Fail sig
                       , Member IO sig
                       )
                    => CreateProcess -> Eff sig (Either String ())
runTaskWithRetryEff procSpec = do
  maxTries <- getMaxTries
  workDir  <- getWorkDir
  logInfo $ "Starting task in " ++ workDir ++ " (max attempts: " ++ show maxTries ++ ")"
  go 0
 where
  go n | n >= maxTries = do
          logInfo "Exceeded max attempts"
          throwError "max attempts exceeded"
        | otherwise = do
          incAttempts
          logInfo $ "Attempt " ++ show (n+1)
          res <- runProcessIO procSpec
          case res of
            Left err -> do
              logInfo $ "Process failed: " ++ err
              markFailed
              go (n+1)
            Right ec -> do
              if ec == ExitSuccess
                then logInfo "Process succeeded"
                else do
                  logInfo $ "Process exited with code: " ++ show ec
                  markFailed
                  go (n+1)

runWorker :: FilePath -> Int -> (String -> IO ()) -> CreateProcess -> IO (Either String ())
runWorker workDir maxTries logger procSpec = do
  let initConf  = #workDir   := workDir
                <+> #maxTries := maxTries
                <+> #logger   := logger
                <+> emptyRecord
      initStats = #attempts := 0
                <+> #failed := False
                <+> emptyRecord
  runM . runTraceIO logger
        . runState initStats
        . runReader initConf
        $ runTaskWithRetryEff procSpec
```

**Key visual differences**

- Field access via `#field` (OverloadedLabels) instead of record selectors or typeclass getters.
- No `Has…` typeclass boilerplate; effects and record fields are declared in open rows.
- State updates use lens‑style operators (`&`, `+~`, `.~`) from the `State` carrier.
- Failure handled via `Fail` effect (`throwError`) interpreted as `Either` in the runner.
- The core logic is concise: each line does one conceptual step (read config, log, update state, run IO, handle result).
- Extending with a new field or effect requires only adding a new entry to the row; existing code unchanged.

Thus the distinctive appearance is the liberal use of `#field` labels, open type‑level rows for both configuration and effects, and a flat `Eff es a` type where each line does exactly one thing, yielding shorter, more modular code compared to the nested transformer stack and `Has` typeclass approach.
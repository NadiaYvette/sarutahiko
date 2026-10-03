#!/usr/bin/env bash
set -euo pipefail

echo "=== [sweep-01] Applying Effect Framework Neutrality via Façade Pattern ==="

# 1. Update Sarutahiko.Effect.Process in sarutahiko-effect-signatures
cat <<'EOF' > packages/sarutahiko/sarutahiko-effect-signatures/src/Sarutahiko/Effect/Process.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Effect.Process
-- Description : Neutral subprocess execution and supervision effect GADT
--
-- Exposes subprocess lifecycle operations per EFFECT_CATALOG_DESIGN.md.
-- Conforms to DECISION-002: strictly zero concrete effect system dependencies.
module Sarutahiko.Effect.Process
  ( -- * Configuration
    ProcessConfig (..)
  , defaultProcessConfig
  , defaultEnvAllowlist

    -- * Signals and Handles
  , ProcessSignal (..)
  , ChildProcessId (..)
  , ChildHandle (..)
  , ProcessTerminationReason (..)

    -- * Effect GADT
  , Process (..)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime)
import Data.Word (Word64)
import System.Exit (ExitCode)

-- | Configuration parameters for launching and supervising a child process.
data ProcessConfig = ProcessConfig
  { cmdPath :: !FilePath           -- ^ Executable path on filesystem
  , cmdArgs :: ![Text]             -- ^ Command-line arguments
  , cmdEnv  :: ![(Text, Text)]     -- ^ Explicit environment variables to inject
  , cmdCwd  :: !(Maybe FilePath)   -- ^ Optional working directory
  , timeout :: !NominalDiffTime    -- ^ Maximum execution deadline before SIGTERM/SIGKILL
  } deriving stock (Eq, Show)

-- | Construct a default 'ProcessConfig' with a 30-second timeout.
defaultProcessConfig :: FilePath -> ProcessConfig
defaultProcessConfig fp = ProcessConfig
  { cmdPath = fp
  , cmdArgs = []
  , cmdEnv  = []
  , cmdCwd  = Nothing
  , timeout = 30
  }

-- | Default host environment variable allowlist for child execution hygiene.
defaultEnvAllowlist :: [Text]
defaultEnvAllowlist =
  [ "PATH"
  , "TERM"
  , "LANG"
  , "LC_ALL"
  , "USER"
  , "HOME"
  , "TMPDIR"
  , "SHELL"
  , "TZ"
  ]

-- | POSIX signals for terminating child processes.
data ProcessSignal
  = SigTerm
  | SigKill
  deriving stock (Eq, Show)

-- | Unique identifier for an active child process.
newtype ChildProcessId = ChildProcessId { unChildProcessId :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | Handle referencing an active child process managed by the supervisor.
data ChildHandle = ChildHandle
  { childId     :: !ChildProcessId
  , childConfig :: !ProcessConfig
  } deriving stock (Eq, Show)

-- | Outcome reason for subprocess supervision.
data ProcessTerminationReason
  = TerminatedExit !ExitCode
  | TerminatedDeadlineExpired
  | TerminatedKilled !ProcessSignal
  | TerminatedAborted !Text
  deriving stock (Eq, Show)

-- | Subprocess lifecycle effect GADT.
data Process (m :: Type -> Type) :: Type -> Type where
  SpawnChild        :: !ProcessConfig -> Process m ChildHandle
  ReadStdout        :: !ChildHandle -> Process m ByteString
  WriteStdin        :: !ChildHandle -> !ByteString -> Process m ()
  WaitChild         :: !ChildHandle -> Process m ExitCode
  PollChild         :: !ChildHandle -> Process m (Maybe ExitCode)
  KillChild         :: !ChildHandle -> !ProcessSignal -> Process m ()
  CloseChildHandles :: !ChildHandle -> Process m ()
EOF

# 2. Update sarutahiko-process.cabal (remove effectful-core)
cat <<'EOF' > packages/sarutahiko/sarutahiko-process/sarutahiko-process.cabal
cabal-version:      3.14
name:               sarutahiko-process
version:            0.1.0.0
synopsis:           Resource-bracketed subprocess supervisor with deadline kills
license:            BSD-3-Clause
author:             Nadia Yvette Chambers
maintainer:         nadia.yvette.chambers@ik.me
category:           System, Process, Effects
build-type:         Simple

common commons
    default-language: GHC2024
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wmissing-home-modules
        -Wpartial-fields
        -Wredundant-constraints
        -Werror

library
    import:           commons
    exposed-modules:
        Sarutahiko.Process
        Sarutahiko.Process.Capability
        Sarutahiko.Process.Supervisor
    build-depends:
        base >= 4.20 && < 5,
        bytestring >= 0.12,
        containers >= 0.6,
        exceptions >= 0.10,
        process >= 1.6,
        text >= 2.1,
        time >= 1.12,
        unix >= 2.8,
        sarutahiko-effect-signatures >= 0.1
    hs-source-dirs:   src

test-suite test-process
    import:           commons
    type:             exitcode-stdio-1.0
    main-is:          Main.hs
    hs-source-dirs:   test
    ghc-options:      -threaded
    build-depends:
        base >= 4.20 && < 5,
        bytestring >= 0.12,
        containers >= 0.6,
        exceptions >= 0.10,
        process >= 1.6,
        text >= 2.1,
        time >= 1.12,
        unix >= 2.8,
        sarutahiko-effect-signatures,
        sarutahiko-process
EOF

# 3. Create Sarutahiko.Process.Capability (tagless façade)
cat <<'EOF' > packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Capability.hs
{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module      : Sarutahiko.Process.Capability
-- Description : Tagless-final capability typeclass for process operations (Façade Pattern)
module Sarutahiko.Process.Capability
  ( MonadProcess (..)
  , withSupervisedChild
  ) where

import Control.Monad.Catch (MonadMask, bracket)
import Data.ByteString (ByteString)
import System.Exit (ExitCode)

import Sarutahiko.Effect.Process
  ( ChildHandle
  , ProcessConfig
  , ProcessSignal (..)
  )

-- | Open tagless capability typeclass exposing subprocess supervision.
class Monad m => MonadProcess m where
  spawnChild        :: ProcessConfig -> m ChildHandle
  readStdout        :: ChildHandle -> m ByteString
  writeStdin        :: ChildHandle -> ByteString -> m ()
  waitChild         :: ChildHandle -> m ExitCode
  pollChild         :: ChildHandle -> m (Maybe ExitCode)
  killChild         :: ChildHandle -> ProcessSignal -> m ()
  closeChildHandles :: ChildHandle -> m ()

-- | Resource-bracketed child process runner ensuring handles are closed
-- and processes terminated if an exception or short-circuit occurs.
withSupervisedChild
  :: (MonadProcess m, MonadMask m)
  => ProcessConfig
  -> (ChildHandle -> m a)
  -> m a
withSupervisedChild cfg = bracket
  (spawnChild cfg)
  (\h -> do
    closeChildHandles h
    killChild h SigTerm
  )
EOF

# 4. Create Sarutahiko.Process.Supervisor (pure IO supervisor)
cat <<'EOF' > packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Supervisor.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.Process.Supervisor
-- Description : POSIX subprocess management and environment hygiene in pure IO
module Sarutahiko.Process.Supervisor
  ( -- * Process Supervisor State
    ProcessTable
  , newProcessTable
  , spawnProcessIO
  , readStdoutIO
  , writeStdinIO
  , waitChildIO
  , pollChildIO
  , killChildIO
  , closeChildHandlesIO
  , cleanseEnvironment
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, catch)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (nominalDiffTimeToSeconds)
import Data.Word (Word64)
import GHC.IO.Handle (BufferMode (..), Handle, hClose, hFlush, hSetBuffering)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import qualified System.Timeout as SysTimeout

import Sarutahiko.Effect.Process
  ( ChildHandle (..)
  , ChildProcessId (..)
  , ProcessConfig (..)
  , ProcessSignal (..)
  , defaultEnvAllowlist
  )

data ProcessEntry = ProcessEntry
  { peHandle       :: !ProcessHandle
  , peStdin        :: !(Maybe Handle)
  , peStdout       :: !(Maybe Handle)
  , peStderr       :: !(Maybe Handle)
  , peWatchdog     :: !(Maybe ThreadId)
  }

type ThreadId = Control.Concurrent.ThreadId

data ProcessTable = ProcessTable
  { ptNextId :: !(IORef Word64)
  , ptProcs  :: !(IORef (Map Word64 ProcessEntry))
  }

newProcessTable :: IO ProcessTable
newProcessTable = do
  idRef <- newIORef 1
  procsRef <- newIORef Map.empty
  pure (ProcessTable idRef procsRef)

spawnProcessIO :: ProcessTable -> ProcessConfig -> IO ChildHandle
spawnProcessIO pt cfg = do
  cleanEnv <- cleanseEnvironment (cmdEnv cfg)
  let cp = (proc (cmdPath cfg) (map T.unpack (cmdArgs cfg)))
        { std_in  = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , env     = Just cleanEnv
        , cwd     = cmdCwd cfg
        }

  (mIn, mOut, mErr, ph) <- createProcess cp

  case mIn of
    Just hIn -> hSetBuffering hIn NoBuffering
    Nothing  -> pure ()
  case mOut of
    Just hOut -> hSetBuffering hOut (BlockBuffering Nothing)
    Nothing   -> pure ()

  cidWord <- atomicModifyIORef' (ptNextId pt) (\curr -> (curr + 1, curr))
  let cid = ChildProcessId cidWord
      handle = ChildHandle cid cfg

  watchdogTid <- if timeout cfg > 0
    then Just <$> forkIO (watchdogThread ph (timeout cfg))
    else pure Nothing

  let entry = ProcessEntry ph mIn mOut mErr watchdogTid
  atomicModifyIORef' (ptProcs pt) (\m -> (Map.insert cidWord entry m, ()))
  pure handle

watchdogThread :: ProcessHandle -> Data.Time.Clock.NominalDiffTime -> IO ()
watchdogThread ph limit = do
  let micros = round (nominalDiffTimeToSeconds limit * 1000000) :: Int
  threadDelay micros
  mExit <- getProcessExitCode ph
  case mExit of
    Just _  -> pure ()
    Nothing -> do
      mPid <- getPid ph
      case mPid of
        Just pid -> do
          catch (signalProcess sigTERM pid) (\(_ :: IOException) -> pure ())
          threadDelay 100000
          mStillRunning <- getProcessExitCode ph
          case mStillRunning of
            Just _  -> pure ()
            Nothing -> catch (signalProcess sigKILL pid) (\(_ :: IOException) -> pure ())
        Nothing -> pure ()

readStdoutIO :: ProcessTable -> ChildHandle -> IO BS.ByteString
readStdoutIO pt (ChildHandle (ChildProcessId cid) _) = do
  m <- readIORef (ptProcs pt)
  case Map.lookup cid m of
    Just entry -> case peStdout entry of
      Just hOut -> BS.hGetSome hOut 4096 `catch` \(_ :: IOException) -> pure BS.empty
      Nothing   -> pure BS.empty
    Nothing -> pure BS.empty

writeStdinIO :: ProcessTable -> ChildHandle -> BS.ByteString -> IO ()
writeStdinIO pt (ChildHandle (ChildProcessId cid) _) bytes = do
  m <- readIORef (ptProcs pt)
  case Map.lookup cid m of
    Just entry -> case peStdin entry of
      Just hIn -> do
        BS.hPut hIn bytes `catch` \(_ :: IOException) -> pure ()
        hFlush hIn `catch` \(_ :: IOException) -> pure ()
      Nothing -> pure ()
    Nothing -> pure ()

waitChildIO :: ProcessTable -> ChildHandle -> IO ExitCode
waitChildIO pt h@(ChildHandle (ChildProcessId cid) _) = do
  m <- readIORef (ptProcs pt)
  case Map.lookup cid m of
    Just entry -> do
      let limitMicros = round (nominalDiffTimeToSeconds (timeout (childConfig h)) * 1000000) :: Int
      mExit <- if limitMicros > 0
        then SysTimeout.timeout limitMicros (waitForProcess (peHandle entry))
        else Just <$> waitForProcess (peHandle entry)
      case mExit of
        Just code -> do
          closeChildHandlesIO pt h
          pure code
        Nothing -> do
          killChildIO pt h SigKill
          closeChildHandlesIO pt h
          pure (ExitFailure (-9))
    Nothing -> pure (ExitFailure 1)

pollChildIO :: ProcessTable -> ChildHandle -> IO (Maybe ExitCode)
pollChildIO pt (ChildHandle (ChildProcessId cid) _) = do
  m <- readIORef (ptProcs pt)
  case Map.lookup cid m of
    Just entry -> getProcessExitCode (peHandle entry)
    Nothing    -> pure (Just (ExitFailure 1))

killChildIO :: ProcessTable -> ChildHandle -> ProcessSignal -> IO ()
killChildIO pt (ChildHandle (ChildProcessId cid) _) sig = do
  m <- readIORef (ptProcs pt)
  case Map.lookup cid m of
    Just entry -> do
      mPid <- getPid (peHandle entry)
      case mPid of
        Just pid -> do
          let posixSig = case sig of
                SigTerm -> sigTERM
                SigKill -> sigKILL
          catch (signalProcess posixSig pid) (\(_ :: IOException) -> pure ())
        Nothing -> pure ()
    Nothing -> pure ()

closeChildHandlesIO :: ProcessTable -> ChildHandle -> IO ()
closeChildHandlesIO pt (ChildHandle (ChildProcessId cid) _) = do
  m <- atomicModifyIORef' (ptProcs pt) (\m -> (Map.delete cid m, Map.lookup cid m))
  case m of
    Just entry -> do
      case peWatchdog entry of
        Just tid -> killThread tid
        Nothing  -> pure ()
      case peStdin entry of
        Just h  -> catch (hClose h) (\(_ :: IOException) -> pure ())
        Nothing -> pure ()
      case peStdout entry of
        Just h  -> catch (hClose h) (\(_ :: IOException) -> pure ())
        Nothing -> pure ()
      case peStderr entry of
        Just h  -> catch (hClose h) (\(_ :: IOException) -> pure ())
        Nothing -> pure ()
    Nothing -> pure ()

cleanseEnvironment :: [(Text, Text)] -> IO [(String, String)]
cleanseEnvironment explicitEnv = do
  hostEnv <- getEnvironment
  let allowSet = defaultEnvAllowlist
      preserved = filter (\(k, _) -> T.pack k `elem` allowSet) hostEnv
      overrides = map (\(k, v) -> (T.unpack k, T.unpack v)) explicitEnv
      merged = Map.toList (Map.union (Map.fromList overrides) (Map.fromList preserved))
  pure merged
EOF

# 5. Update Sarutahiko.Process module to re-export Capability & Supervisor
rm -f packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Signature.hs
rm -f packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Interpreter.hs
cat <<'EOF' > packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process.hs
-- |
-- Module      : Sarutahiko.Process
-- Description : Subprocess supervisor and tagless capability façade
--
-- Re-exports the canonical Process GADT from 'sarutahiko-effect-signatures',
-- the open 'MonadProcess' capability typeclass, and pure POSIX supervisor.
module Sarutahiko.Process
  ( module Sarutahiko.Effect.Process
  , module Sarutahiko.Process.Capability
  , module Sarutahiko.Process.Supervisor
  ) where

import Sarutahiko.Effect.Process
import Sarutahiko.Process.Capability
import Sarutahiko.Process.Supervisor
EOF

# 6. Update sarutahiko-mcp.cabal (remove effectful-core)
sed -i '/effectful-core >= 2.3/d' packages/sarutahiko/sarutahiko-mcp/sarutahiko-mcp.cabal

# 7. Update sarutahiko-effect-effectful to implement MonadProcess
sed -i 's/sarutahiko-records/sarutahiko-records, sarutahiko-process/' packages/sarutahiko/sarutahiko-effect-effectful/sarutahiko-effect-effectful.cabal

cat <<'EOF' > packages/sarutahiko/sarutahiko-effect-effectful/src/Sarutahiko/Effect/Interpreter/Effectful.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Sarutahiko.Effect.Interpreter.Effectful
-- Description : Production and in-memory effectful interpreters for core signatures
module Sarutahiko.Effect.Interpreter.Effectful
  ( -- * Clock Interpreters
    runClockPure
  , runClockIO

    -- * Resource Interpreters
  , runResourcePure
  , runResourceIO

    -- * Process Interpreters
  , MockProcessState (..)
  , emptyMockProcessState
  , runProcessMock
  , runProcessIO

    -- * Log Interpreters
  , LoggedRecord (..)
  , runLogPure
  , runLogIO

    -- * Smart Senders
  , getCurrentTimeEff
  , getMonotonicTimeEff
  , sleepEff
  , allocateEff
  , releaseEff
  , logEntryEff
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import System.Exit (ExitCode (..))

import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Effect.Clock (Clock (..))
import Sarutahiko.Effect.Log (Log (..), LogSeverity (..), SomeRow (..))
import Sarutahiko.Effect.Process
  ( ChildHandle (..)
  , ChildProcessId (..)
  , Process (..)
  , ProcessConfig (..)
  , ProcessSignal (..)
  )
import Sarutahiko.Effect.Resource (Resource (..), ResourceKey (..))
import Sarutahiko.Process.Capability (MonadProcess (..))
import qualified Sarutahiko.Process.Supervisor as Sup

type instance DispatchOf Clock    = Dynamic
type instance DispatchOf Resource = Dynamic
type instance DispatchOf Process  = Dynamic
type instance DispatchOf Log      = Dynamic

instance (Process :> es) => MonadProcess (Eff es) where
  spawnChild        = send . SpawnChild
  readStdout        = send . ReadStdout
  writeStdin h bs   = send (WriteStdin h bs)
  waitChild         = send . WaitChild
  pollChild         = send . PollChild
  killChild h sig   = send (KillChild h sig)
  closeChildHandles = send . CloseChildHandles

getCurrentTimeEff :: (Clock :> es) => Eff es UTCTime
getCurrentTimeEff = send GetCurrentTime

getMonotonicTimeEff :: (Clock :> es) => Eff es Double
getMonotonicTimeEff = send GetMonotonicTime

sleepEff :: (Clock :> es) => NominalDiffTime -> Eff es ()
sleepEff = send . Sleep

allocateEff :: (Resource :> es) => Eff es () -> Eff es ResourceKey
allocateEff = send . Allocate

releaseEff :: (Resource :> es) => ResourceKey -> Eff es ()
releaseEff = send . Release

logEntryEff :: (Log :> es) => LogSeverity -> SomeRow -> Eff es ()
logEntryEff sev r = send (LogEntry sev r)

runClockPure :: (IOE :> es) => UTCTime -> IORef Double -> Eff (Clock : es) a -> Eff es a
runClockPure fixedUtc timeRef = interpret $ \_ -> \case
  GetCurrentTime   -> pure fixedUtc
  GetMonotonicTime -> liftIO $ readIORef timeRef
  Sleep dt         -> liftIO $ modifyIORef' timeRef (+ realToFrac dt)

runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ -> \case
  GetCurrentTime   -> liftIO getCurrentTime
  GetMonotonicTime -> liftIO getMonotonicTime
  Sleep dt         -> liftIO $ threadDelay (round (nominalDiffTimeToSeconds dt * 1e6))

runResourcePure :: (IOE :> es) => IORef [Text] -> Eff (Resource : es) a -> Eff es a
runResourcePure logRef = interpret $ \env -> \case
  Allocate finalizer -> do
    let key = ResourceKey 100
    liftIO $ modifyIORef' logRef (\s -> "allocated:100" : s)
    localSeqUnlift env $ \unlift -> unlift finalizer
    pure key
  Release (ResourceKey k) ->
    liftIO $ modifyIORef' logRef (\s -> ("released:" <> showText k) : s)
  where
    showText :: Word64 -> Text
    showText = T.pack . show

runResourceIO :: Eff (Resource : es) a -> Eff es a
runResourceIO = interpret $ \env -> \case
  Allocate finalizer -> do
    localSeqUnlift env $ \unlift -> unlift finalizer
    pure (ResourceKey 1)
  Release _ -> pure ()

data MockProcessState = MockProcessState
  { mockSpawnCount :: !Word64
  , mockProcesses  :: !(Map Word64 (ProcessConfig, ByteString, ExitCode))
  } deriving stock (Eq, Show)

emptyMockProcessState :: MockProcessState
emptyMockProcessState = MockProcessState 0 Map.empty

runProcessMock
  :: (IOE :> es)
  => IORef MockProcessState
  -> Eff (Process : es) a
  -> Eff es a
runProcessMock ref = interpret $ \_ -> \case
  SpawnChild cfg -> liftIO $ do
    st <- readIORef ref
    let newId = mockSpawnCount st + 1
        fakeOutput = "mock_output_for:" <> TE.encodeUtf8 (T.pack (cmdPath cfg))
        newProcs = Map.insert newId (cfg, fakeOutput, ExitSuccess) (mockProcesses st)
    writeIORef ref (MockProcessState newId newProcs)
    pure (ChildHandle (ChildProcessId newId) cfg)
  ReadStdout (ChildHandle (ChildProcessId cid) _) -> liftIO $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, out, _) -> pure out
      Nothing          -> pure ""
  WriteStdin _ _ -> pure ()
  WaitChild (ChildHandle (ChildProcessId cid) _) -> liftIO $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure code
      Nothing           -> pure (ExitFailure 1)
  PollChild (ChildHandle (ChildProcessId cid) _) -> liftIO $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure (Just code)
      Nothing           -> pure (Just (ExitFailure 1))
  KillChild (ChildHandle (ChildProcessId cid) _) _ -> liftIO $ do
    modifyIORef' ref $ \st ->
      st { mockProcesses = Map.delete cid (mockProcesses st) }
  CloseChildHandles _ -> pure ()

runProcessIO :: (IOE :> es) => Sup.ProcessTable -> Eff (Process : es) a -> Eff es a
runProcessIO pt = interpret $ \_ -> \case
  SpawnChild cfg        -> liftIO $ Sup.spawnProcessIO pt cfg
  ReadStdout h          -> liftIO $ Sup.readStdoutIO pt h
  WriteStdin h bs       -> liftIO $ Sup.writeStdinIO pt h bs
  WaitChild h           -> liftIO $ Sup.waitChildIO pt h
  PollChild h           -> liftIO $ Sup.pollChildIO pt h
  KillChild h sig       -> liftIO $ Sup.killChildIO pt h sig
  CloseChildHandles h   -> liftIO $ Sup.closeChildHandlesIO pt h

data LoggedRecord = LoggedRecord
  { logRecSeverity :: !LogSeverity
  , logRecTag      :: !Text
  } deriving stock (Eq, Show)

runLogPure :: (IOE :> es) => IORef [LoggedRecord] -> Eff (Log : es) a -> Eff es a
runLogPure ref = interpret $ \_ -> \case
  LogEntry sev (SomeRow tag _) -> liftIO $ do
    modifyIORef' ref (LoggedRecord sev tag :)

runLogIO :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLogIO = interpret $ \_ -> \case
  LogEntry sev (SomeRow tag _) -> liftIO $ do
    putStrLn $ "[" ++ show sev ++ "] " ++ T.unpack tag
EOF

# 8. Update sarutahiko-effect-polysemy to implement MonadProcess
sed -i 's/sarutahiko-records/sarutahiko-records, sarutahiko-process/' packages/sarutahiko/sarutahiko-effect-polysemy/sarutahiko-effect-polysemy.cabal

cat <<'EOF' > packages/sarutahiko/sarutahiko-effect-polysemy/src/Sarutahiko/Effect/Interpreter/Polysemy.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Sarutahiko.Effect.Interpreter.Polysemy
-- Description : Polysemy seam compatibility interpreters for core signatures
module Sarutahiko.Effect.Interpreter.Polysemy
  ( -- * Clock Interpreters
    runClockPurePoly
  , runClockIOPoly

    -- * Resource Interpreters
  , runResourcePurePoly
  , runResourceIOPoly

    -- * Process Interpreters
  , runProcessMockPoly
  , runProcessIOPoly

    -- * Log Interpreters
  , runLogPurePoly
  , runLogIOPoly

    -- * Smart Senders
  , getCurrentTimePoly
  , getMonotonicTimePoly
  , sleepPoly
  , allocatePoly
  , releasePoly
  , logEntryPoly
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import System.Exit (ExitCode (..))

import qualified Polysemy as P

import Sarutahiko.Effect.Clock (Clock (..))
import Sarutahiko.Effect.Interpreter.Effectful
  ( LoggedRecord (..)
  , MockProcessState (..)
  )
import Sarutahiko.Effect.Log (Log (..), LogSeverity (..), SomeRow (..))
import Sarutahiko.Effect.Process
  ( ChildHandle (..)
  , ChildProcessId (..)
  , Process (..)
  , ProcessConfig (..)
  , ProcessSignal (..)
  )
import Sarutahiko.Effect.Resource (Resource (..), ResourceKey (..))
import Sarutahiko.Process.Capability (MonadProcess (..))
import qualified Sarutahiko.Process.Supervisor as Sup

instance (P.Member Process r) => MonadProcess (P.Sem r) where
  spawnChild        = P.send . SpawnChild
  readStdout        = P.send . ReadStdout
  writeStdin h bs   = P.send (WriteStdin h bs)
  waitChild         = P.send . WaitChild
  pollChild         = P.send . PollChild
  killChild h sig   = P.send (KillChild h sig)
  closeChildHandles = P.send . CloseChildHandles

getCurrentTimePoly :: (P.Member Clock r) => P.Sem r UTCTime
getCurrentTimePoly = P.send GetCurrentTime

getMonotonicTimePoly :: (P.Member Clock r) => P.Sem r Double
getMonotonicTimePoly = P.send GetMonotonicTime

sleepPoly :: (P.Member Clock r) => NominalDiffTime -> P.Sem r ()
sleepPoly = P.send . Sleep

allocatePoly :: (P.Member Resource r) => P.Sem r () -> P.Sem r ResourceKey
allocatePoly = P.send . Allocate

releasePoly :: (P.Member Resource r) => ResourceKey -> P.Sem r ()
releasePoly = P.send . Release

logEntryPoly :: (P.Member Log r) => LogSeverity -> SomeRow -> P.Sem r ()
logEntryPoly sev r = P.send (LogEntry sev r)

runClockPurePoly
  :: (P.Member (P.Embed IO) r)
  => UTCTime
  -> IORef Double
  -> P.Sem (Clock : r) a
  -> P.Sem r a
runClockPurePoly fixedUtc timeRef = P.interpret $ \case
  GetCurrentTime   -> pure fixedUtc
  GetMonotonicTime -> P.embed $ readIORef timeRef
  Sleep dt         -> P.embed $ modifyIORef' timeRef (+ realToFrac dt)

runClockIOPoly :: (P.Member (P.Embed IO) r) => P.Sem (Clock : r) a -> P.Sem r a
runClockIOPoly = P.interpret $ \case
  GetCurrentTime   -> P.embed getCurrentTime
  GetMonotonicTime -> P.embed getMonotonicTime
  Sleep dt         -> P.embed $ threadDelay (round (nominalDiffTimeToSeconds dt * 1e6))

runResourcePurePoly
  :: (P.Member (P.Embed IO) r)
  => IORef [Text]
  -> P.Sem (Resource : r) a
  -> P.Sem r a
runResourcePurePoly logRef = P.interpretH $ \case
  Allocate finalizer -> do
    let key = ResourceKey 100
    P.embed $ modifyIORef' logRef (\s -> "allocated:100" : s)
    finT <- P.runTSimple finalizer
    _ <- P.raise finT
    pureT key
  Release (ResourceKey k) -> do
    P.embed $ modifyIORef' logRef (\s -> ("released:" <> showText k) : s)
    pureT ()
  where
    pureT = P.pureT
    showText :: Word64 -> Text
    showText = T.pack . show

runResourceIOPoly :: P.Sem (Resource : r) a -> P.Sem r a
runResourceIOPoly = P.interpretH $ \case
  Allocate finalizer -> do
    finT <- P.runTSimple finalizer
    _ <- P.raise finT
    P.pureT (ResourceKey 1)
  Release _ -> P.pureT ()

runProcessMockPoly
  :: (P.Member (P.Embed IO) r)
  => IORef MockProcessState
  -> P.Sem (Process : r) a
  -> P.Sem r a
runProcessMockPoly ref = P.interpret $ \case
  SpawnChild cfg -> P.embed $ do
    st <- readIORef ref
    let newId = mockSpawnCount st + 1
        fakeOutput = "mock_output_for:" <> TE.encodeUtf8 (T.pack (cmdPath cfg))
        newProcs = Map.insert newId (cfg, fakeOutput, ExitSuccess) (mockProcesses st)
    writeIORef ref (MockProcessState newId newProcs)
    pure (ChildHandle (ChildProcessId newId) cfg)
  ReadStdout (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, out, _) -> pure out
      Nothing          -> pure ""
  WriteStdin _ _ -> pure ()
  WaitChild (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure code
      Nothing           -> pure (ExitFailure 1)
  PollChild (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure (Just code)
      Nothing           -> pure (Just (ExitFailure 1))
  KillChild (ChildHandle (ChildProcessId cid) _) _ -> P.embed $ do
    modifyIORef' ref $ \st ->
      st { mockProcesses = Map.delete cid (mockProcesses st) }
  CloseChildHandles _ -> pure ()

runProcessIOPoly
  :: (P.Member (P.Embed IO) r)
  => Sup.ProcessTable
  -> P.Sem (Process : r) a
  -> P.Sem r a
runProcessIOPoly pt = P.interpret $ \case
  SpawnChild cfg        -> P.embed $ Sup.spawnProcessIO pt cfg
  ReadStdout h          -> P.embed $ Sup.readStdoutIO pt h
  WriteStdin h bs       -> P.embed $ Sup.writeStdinIO pt h bs
  WaitChild h           -> P.embed $ Sup.waitChildIO pt h
  PollChild h           -> P.embed $ Sup.pollChildIO pt h
  KillChild h sig       -> P.embed $ Sup.killChildIO pt h sig
  CloseChildHandles h   -> P.embed $ Sup.closeChildHandlesIO pt h

runLogPurePoly
  :: (P.Member (P.Embed IO) r)
  => IORef [LoggedRecord]
  -> P.Sem (Log : r) a
  -> P.Sem r a
runLogPurePoly ref = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    modifyIORef' ref (LoggedRecord sev tag :)

runLogIOPoly :: (P.Member (P.Embed IO) r) => P.Sem (Log : r) a -> P.Sem r a
runLogIOPoly = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    putStrLn $ "[" ++ show sev ++ "] " ++ T.unpack tag
EOF

# 9. Update sarutahiko-effect-testkit
cat <<'EOF' > packages/sarutahiko/sarutahiko-effect-testkit/src/Sarutahiko/Effect/Testkit/Parity.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

-- |
-- Module      : Sarutahiko.Effect.Testkit.Parity
-- Description : Dual-interpreter parity testkit executing identical programs
module Sarutahiko.Effect.Testkit.Parity
  ( ClockParityResult (..)
  , ResourceParityResult (..)
  , ProcessParityResult (..)
  , LogParityResult (..)
  , runClockParity
  , runResourceParity
  , runProcessParity
  , runLogParity
  ) where

import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity (..))
import Data.IORef (newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Record.Anon.Advanced as Anon
import Data.Text (Text)
import Data.Time.Clock (UTCTime, secondsToNominalDiffTime)
import System.Exit (ExitCode (..))

import Effectful
import qualified Polysemy as P

import Sarutahiko.Effect.Interpreter.Effectful
  ( LoggedRecord (..)
  , MockProcessState (..)
  , allocateEff
  , emptyMockProcessState
  , getCurrentTimeEff
  , getMonotonicTimeEff
  , logEntryEff
  , releaseEff
  , runClockPure
  , runLogPure
  , runProcessMock
  , runResourcePure
  , sleepEff
  )
import Sarutahiko.Effect.Interpreter.Polysemy
  ( allocatePoly
  , getCurrentTimePoly
  , getMonotonicTimePoly
  , logEntryPoly
  , releasePoly
  , runClockPurePoly
  , runLogPurePoly
  , runProcessMockPoly
  , runResourcePurePoly
  , sleepPoly
  )
import Sarutahiko.Effect.Log (LogSeverity (..), SomeRow (..))
import Sarutahiko.Effect.Process
  ( ChildHandle (..)
  , ChildProcessId (..)
  , ProcessConfig (..)
  , defaultProcessConfig
  )
import Sarutahiko.Process.Capability (MonadProcess (..))

data ClockParityResult = ClockParityResult
  { clkFinalUtc    :: !UTCTime
  , clkMonotonicT0 :: !Double
  , clkMonotonicT1 :: !Double
  } deriving stock (Eq, Show)

runClockParity :: UTCTime -> IO (ClockParityResult, ClockParityResult)
runClockParity testUtc = do
  effRef <- newIORef (100.0 :: Double)
  (effPre, effPost, effUtc) <- runEff . runClockPure testUtc effRef $ do
    t0 <- getMonotonicTimeEff
    sleepEff (secondsToNominalDiffTime 0.5)
    t1 <- getMonotonicTimeEff
    utc <- getCurrentTimeEff
    pure (t0, t1, utc)
  let effRes = ClockParityResult effUtc effPre effPost

  polyRef <- newIORef (100.0 :: Double)
  (polyPre, polyPost, polyUtc) <- P.runM . runClockPurePoly testUtc polyRef $ do
    t0 <- getMonotonicTimePoly
    sleepPoly (secondsToNominalDiffTime 0.5)
    t1 <- getMonotonicTimePoly
    utc <- getCurrentTimePoly
    pure (t0, t1, utc)
  let polyRes = ClockParityResult polyUtc polyPre polyPost

  pure (effRes, polyRes)

data ResourceParityResult = ResourceParityResult
  { resEventLog :: ![Text]
  } deriving stock (Eq, Show)

runResourceParity :: IO (ResourceParityResult, ResourceParityResult)
runResourceParity = do
  effLogRef <- newIORef []
  runEff . runResourcePure effLogRef $ do
    k <- allocateEff (pure ())
    releaseEff k
  effEvents <- readIORef effLogRef
  let effRes = ResourceParityResult effEvents

  polyLogRef <- newIORef []
  P.runM . runResourcePurePoly polyLogRef $ do
    k <- allocatePoly (pure ())
    releasePoly k
  polyEvents <- readIORef polyLogRef
  let polyRes = ResourceParityResult polyEvents

  pure (effRes, polyRes)

data ProcessParityResult = ProcessParityResult
  { procHandleId :: !ChildProcessId
  , procStdout   :: !ByteString
  , procExit     :: !ExitCode
  , procMapEmpty :: !Bool
  } deriving stock (Eq, Show)

runProcessParity :: IO (ProcessParityResult, ProcessParityResult)
runProcessParity = do
  let cfg = defaultProcessConfig "/bin/echo"

  -- Effectful run
  effRef <- newIORef emptyMockProcessState
  (effH, effOut, effCode) <- runEff . runProcessMock effRef $ do
    h <- spawnChild cfg
    out <- readStdout h
    c <- waitChild h
    killChild h Sarutahiko.Effect.Process.SigTerm
    pure (h, out, c)
  effSt <- readIORef effRef
  let effRes = ProcessParityResult (childId effH) effOut effCode (Map.null (mockProcesses effSt))

  -- Polysemy run
  polyRef <- newIORef emptyMockProcessState
  (polyH, polyOut, polyCode) <- P.runM . runProcessMockPoly polyRef $ do
    h <- spawnChild cfg
    out <- readStdout h
    c <- waitChild h
    killChild h Sarutahiko.Effect.Process.SigTerm
    pure (h, out, c)
  polySt <- readIORef polyRef
  let polyRes = ProcessParityResult (childId polyH) polyOut polyCode (Map.null (mockProcesses polySt))

  pure (effRes, polyRes)

data LogParityResult = LogParityResult
  { logEvents :: ![(LogSeverity, Text)]
  } deriving stock (Eq, Show)

runLogParity :: IO (LogParityResult, LogParityResult)
runLogParity = do
  let rowVal = Anon.insert #user (Identity ("test_user" :: Text))
             $ Anon.insert #status (Identity (200 :: Int))
             $ Anon.empty
      entry = SomeRow "request_completed" rowVal

  effLogRef <- newIORef []
  runEff . runLogPure effLogRef $ do
    logEntryEff Info entry
  effEvents <- map (\r -> (logRecSeverity r, logRecTag r)) <$> readIORef effLogRef
  let effRes = LogParityResult effEvents

  polyLogRef <- newIORef []
  P.runM . runLogPurePoly polyLogRef $ do
    logEntryPoly Info entry
  polyEvents <- map (\r -> (logRecSeverity r, logRecTag r)) <$> readIORef polyLogRef
  let polyRes = LogParityResult polyEvents

  pure (effRes, polyRes)
EOF

# 10. Update test-process in sarutahiko-process
cat <<'EOF' > packages/sarutahiko/sarutahiko-process/test/Main.hs
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)

import Sarutahiko.Process

main :: IO ()
main = do
  putStrLn "=== Running sarutahiko-process supervisor tests ==="
  pt <- newProcessTable
  let cfg = (defaultProcessConfig "echo") { cmdArgs = ["hello_process"] }
  h <- spawnProcessIO pt cfg
  out <- readStdoutIO pt h
  code <- waitChildIO pt h
  closeChildHandlesIO pt h
  unless (code == ExitSuccess) $ do
    putStrLn $ "Expected ExitSuccess, got: " ++ show code
    exitFailure
  putStrLn "  [PASS] Subprocess spawned and waited successfully."
  exitSuccess
EOF

echo "=== [sweep-01] Transformation script complete ==="

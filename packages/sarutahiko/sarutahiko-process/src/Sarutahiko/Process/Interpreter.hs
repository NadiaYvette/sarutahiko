{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Process.Interpreter
-- Description : Production effectful interpreter and resource-bracketed supervisor
--
-- Implements Invariant 1 (Fail-Closed Termination & Deadline Kills)
-- and Invariant 2 (Environment Hygiene) per TP-1.4 and Closure 4.
module Sarutahiko.Process.Interpreter
  ( -- * Interpreters
    runProcessIO
  , withSupervisedChild
  , superviseTeardown
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

import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Exception (bracket)

import Sarutahiko.Process.Signature
  ( ChildHandle (..)
  , ChildProcessId (..)
  , Process (..)
  , ProcessConfig (..)
  , ProcessSignal (..)
  , ProcessTerminationReason (..)
  , closeChildHandlesEff
  , defaultEnvAllowlist
  , killChildEff
  , pollChildEff
  , spawnChildEff
  , waitChildEff
  )

-- | Internal metadata tracking an active OS process.
data ProcessEntry = ProcessEntry
  { peHandle :: !ProcessHandle
  , peStdin  :: !(Maybe Handle)
  , peStdout :: !(Maybe Handle)
  , peStderr :: !(Maybe Handle)
  , peConfig :: !ProcessConfig
  }

-- | Cleanse host environment variables by enforcing an allowlist
-- and merging explicit child variables.
--
-- Satisfies Invariant 2: Host environment variables are scrubbed by default.
-- Only variables in 'defaultEnvAllowlist' or explicitly passed in 'cmdEnv' are preserved.
cleanseEnvironment :: [(String, String)] -> [(Text, Text)] -> [(String, String)]
cleanseEnvironment hostEnv explicitEnv =
  let hostAllowed = [ (k, v) | (k, v) <- hostEnv, T.pack k `elem` defaultEnvAllowlist ]
      explicitMap = [ (T.unpack k, T.unpack v) | (k, v) <- explicitEnv ]
      explicitKeys = map fst explicitMap
      filteredHost = [ (k, v) | (k, v) <- hostAllowed, k `notElem` explicitKeys ]
  in explicitMap ++ filteredHost

-- | Production 'Process' interpreter backed by 'System.Process' and POSIX signals.
runProcessIO :: (IOE :> es) => Eff (Process : es) a -> Eff es a
runProcessIO action = do
  stateRef <- liftIO $ newIORef (0 :: Word64, Map.empty :: Map Word64 ProcessEntry)
  interpret (\_ -> handleProcess stateRef) action

handleProcess
  :: (IOE :> es)
  => IORef (Word64, Map Word64 ProcessEntry)
  -> Process (Eff localEs) b
  -> Eff es b
handleProcess stateRef = \case
  SpawnChild cfg -> liftIO $ do
    hostEnv <- getEnvironment
    let cleanEnv = cleanseEnvironment hostEnv (cmdEnv cfg)
        cmdSpec = (proc (cmdPath cfg) (map T.unpack (cmdArgs cfg)))
          { cwd = cmdCwd cfg
          , env = Just cleanEnv
          , std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          , close_fds = True
          }
    (mIn, mOut, mErr, ph) <- createProcess cmdSpec
    case mIn of
      Just hIn  -> hSetBuffering hIn NoBuffering
      Nothing   -> pure ()
    case mOut of
      Just hOut -> hSetBuffering hOut NoBuffering
      Nothing   -> pure ()
    let entry = ProcessEntry
          { peHandle = ph
          , peStdin  = mIn
          , peStdout = mOut
          , peStderr = mErr
          , peConfig = cfg
          }
    newId <- atomicModifyIORef' stateRef $ \(cnt, m) ->
      let nid = cnt + 1
      in ((nid, Map.insert nid entry m), nid)
    pure $ ChildHandle (ChildProcessId newId) cfg

  ReadStdout (ChildHandle (ChildProcessId pid) _) -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> case peStdout entry of
        Just hOut -> BS.hGetSome hOut 65536
        Nothing   -> pure BS.empty
      Nothing -> pure BS.empty

  WriteStdin (ChildHandle (ChildProcessId pid) _) bs -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> case peStdin entry of
        Just hIn -> do
          BS.hPut hIn bs
          hFlush hIn
        Nothing  -> pure ()
      Nothing -> pure ()

  WaitChild (ChildHandle (ChildProcessId pid) _) -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> waitForProcess (peHandle entry)
      Nothing -> pure (ExitFailure 1)

  PollChild (ChildHandle (ChildProcessId pid) _) -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> getProcessExitCode (peHandle entry)
      Nothing    -> pure Nothing

  KillChild (ChildHandle (ChildProcessId pid) _) sig -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> do
        mPid <- getPid (peHandle entry)
        case mPid of
          Just p -> do
            let posixSig = case sig of
                  SigTerm -> sigTERM
                  SigKill -> sigKILL
            signalProcess posixSig p `catch` (\(_ :: IOException) -> pure ())
          Nothing -> pure ()
      Nothing -> pure ()

  CloseChildHandles (ChildHandle (ChildProcessId pid) _) -> liftIO $ do
    (_, m) <- readIORef stateRef
    case Map.lookup pid m of
      Just entry -> closeHandles entry
      Nothing    -> pure ()

-- | Close all open stdio handles associated with a process entry.
closeHandles :: ProcessEntry -> IO ()
closeHandles entry = do
  case peStdin entry of
    Just h  -> hClose h `catch` (\(_ :: IOException) -> pure ())
    Nothing -> pure ()
  case peStdout entry of
    Just h  -> hClose h `catch` (\(_ :: IOException) -> pure ())
    Nothing -> pure ()
  case peStderr entry of
    Just h  -> hClose h `catch` (\(_ :: IOException) -> pure ())
    Nothing -> pure ()

-- | Run a computation with a supervised child process.
--
-- Implements Invariant 1 (Fail-Closed Termination):
-- When the deadline expires or the computation aborts, SIGTERM is sent immediately.
-- If the process does not terminate within 500ms, SIGKILL is sent.
-- All child processes are reaped to prevent zombies.
withSupervisedChild
  :: forall es a. (Process :> es, IOE :> es)
  => ProcessConfig
  -> (ChildHandle -> Eff es a)
  -> Eff es (Either ProcessTerminationReason a)
withSupervisedChild cfg action = do
  deadlineExpiredRef <- liftIO $ newIORef False
  bracket
    (spawnChildEff cfg)
    superviseTeardown
    (\child -> do
        let micros = round (nominalDiffTimeToSeconds (timeout cfg) * 1e6)
        watchdogTid <- withEffToIO (ConcUnlift Persistent Unlimited) $ \toIO ->
          forkIO $ do
            threadDelay micros
            mExit <- toIO (pollChildEff child)
            case mExit of
              Just _  -> pure ()
              Nothing -> do
                writeIORef deadlineExpiredRef True
                toIO (killChildEff child SigTerm)
                let pollWait (0 :: Int) = pure False
                    pollWait n = do
                      threadDelay 10000
                      mCode <- toIO (pollChildEff child)
                      case mCode of
                        Just _  -> pure True
                        Nothing -> pollWait (n - 1)
                exited <- pollWait 50
                unless exited $ do
                  toIO (killChildEff child SigKill)
        bracket
          (pure watchdogTid)
          (\tid -> liftIO $ killThread tid)
          (\_ -> do
              mRes <- withEffToIO SeqUnlift $ \toIO ->
                SysTimeout.timeout (micros + 700000) (toIO (action child))
              isExpired <- liftIO $ readIORef deadlineExpiredRef
              if isExpired
                then pure (Left TerminatedDeadlineExpired)
                else case mRes of
                  Nothing  -> pure (Left TerminatedDeadlineExpired)
                  Just res -> pure (Right res)
          )
    )

-- | Teardown a child process using the 500ms SIGTERM -> SIGKILL ladder.
superviseTeardown :: (Process :> es, IOE :> es) => ChildHandle -> Eff es ()
superviseTeardown child = do
  mExit <- pollChildEff child
  case mExit of
    Just _  -> pure ()
    Nothing -> do
      -- 1. Send SIGTERM immediately
      killChildEff child SigTerm
      -- 2. Wait up to 500ms (50 * 10ms)
      exited <- waitForExitPoll child (50 :: Int) (10000 :: Int)
      unless exited $ do
        -- 3. If not exited within 500ms, issue SIGKILL
        killChildEff child SigKill
      -- 4. Reap child to prevent zombie
      _ <- waitChildEff child
      pure ()
  closeChildHandlesEff child
  where
    waitForExitPoll _ 0 _ = pure False
    waitForExitPoll ch count delay = do
      liftIO $ threadDelay delay
      mCode <- pollChildEff ch
      case mCode of
        Just _  -> pure True
        Nothing -> waitForExitPoll ch (count - 1) delay

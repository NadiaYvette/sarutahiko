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

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Exception (IOException, catch)
import qualified Data.ByteString as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, nominalDiffTimeToSeconds)
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

watchdogThread :: ProcessHandle -> NominalDiffTime -> IO ()
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

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
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

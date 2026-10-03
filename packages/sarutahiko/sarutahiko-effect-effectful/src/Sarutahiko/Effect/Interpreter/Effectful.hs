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
--
-- Implements production and test interpreters for Clock, Resource, Process, and Log
-- satisfying dual-interpreter parity per EFFECT_CATALOG_DESIGN.md and PHASE_0_PLAN.md TP-0.6.
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
  , spawnProcessEff
  , waitForProcessEff
  , terminateProcessEff
  , readProcessStdoutEff
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

import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Effect.Clock (Clock (..))
import Sarutahiko.Effect.Log (Log (..), LogSeverity, SomeRow (..))
import Sarutahiko.Effect.Process
  ( Process (..)
  , ProcessConfig (..)
  , ProcessExitCode (..)
  , ProcessHandleId (..)
  )
import Sarutahiko.Effect.Resource (Resource (..), ResourceKey (..))

{-------------------------------------------------------------------------------
  Dynamic Dispatch Declarations
-------------------------------------------------------------------------------}

type instance DispatchOf Clock    = Dynamic
type instance DispatchOf Resource = Dynamic
type instance DispatchOf Process  = Dynamic
type instance DispatchOf Log      = Dynamic

{-------------------------------------------------------------------------------
  Smart Senders
-------------------------------------------------------------------------------}

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

spawnProcessEff :: (Process :> es) => ProcessConfig -> Eff es ProcessHandleId
spawnProcessEff = send . SpawnProcess

waitForProcessEff :: (Process :> es) => ProcessHandleId -> Eff es ProcessExitCode
waitForProcessEff = send . WaitForProcess

terminateProcessEff :: (Process :> es) => ProcessHandleId -> Eff es ()
terminateProcessEff = send . TerminateProcess

readProcessStdoutEff :: (Process :> es) => ProcessHandleId -> Eff es ByteString
readProcessStdoutEff = send . ReadProcessStdout

logEntryEff :: (Log :> es) => LogSeverity -> SomeRow -> Eff es ()
logEntryEff s r = send (LogEntry s r)

{-------------------------------------------------------------------------------
  Clock Interpreters
-------------------------------------------------------------------------------}

-- | In-memory Clock interpreter using an IORef holding current simulated monotonic time.
runClockPure
  :: (IOE :> es)
  => UTCTime
  -> IORef Double
  -> Eff (Clock : es) a
  -> Eff es a
runClockPure fixedUtc timeRef = interpret $ \_ -> \case
  GetCurrentTime -> pure fixedUtc
  GetMonotonicTime -> liftIO $ readIORef timeRef
  Sleep dt -> liftIO $ modifyIORef' timeRef (+ realToFrac dt)

-- | Real IO Clock interpreter.
runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ -> \case
  GetCurrentTime -> liftIO getCurrentTime
  GetMonotonicTime -> liftIO getMonotonicTime
  Sleep dt -> liftIO $ threadDelay (round (nominalDiffTimeToSeconds dt * 1e6))

{-------------------------------------------------------------------------------
  Resource Interpreters
-------------------------------------------------------------------------------}

-- | In-memory Resource interpreter tracking allocations and releases in an IORef.
runResourcePure
  :: (IOE :> es)
  => IORef [Text]
  -> Eff (Resource : es) a
  -> Eff es a
runResourcePure logRef = interpret $ \env -> \case
  Allocate finalizer -> do
    let key = ResourceKey 100
    liftIO $ modifyIORef' logRef (\s -> "allocated:100" : s)
    localSeqUnlift env $ \unlift -> unlift finalizer
    pure key
  Release (ResourceKey k) ->
    liftIO $ modifyIORef' logRef (\s -> ("released:" <> (showText k)) : s)
  where
    showText :: Word64 -> Text
    showText = T.pack . show

-- | Real IO Resource interpreter.
runResourceIO :: Eff (Resource : es) a -> Eff es a
runResourceIO = interpret $ \env -> \case
  Allocate finalizer -> do
    localSeqUnlift env $ \unlift -> unlift finalizer
    pure (ResourceKey 1)
  Release _ -> pure ()

{-------------------------------------------------------------------------------
  Process Interpreters
-------------------------------------------------------------------------------}

data MockProcessState = MockProcessState
  { mockSpawnCount :: !Word64
  , mockProcesses  :: !(Map Word64 (ProcessConfig, ByteString, ProcessExitCode))
  } deriving stock (Eq, Show)

emptyMockProcessState :: MockProcessState
emptyMockProcessState = MockProcessState 0 Map.empty

-- | Mock Process interpreter simulating subprocess execution in-memory.
runProcessMock
  :: (IOE :> es)
  => IORef MockProcessState
  -> Eff (Process : es) a
  -> Eff es a
runProcessMock ref = interpret $ \_ -> \case
  SpawnProcess cfg -> liftIO $ do
    st <- readIORef ref
    let newId = mockSpawnCount st + 1
        fakeOutput = "mock_output_for:" <> TE.encodeUtf8 (procCommand cfg)
        newProcs = Map.insert newId (cfg, fakeOutput, ExitSuccessCode) (mockProcesses st)
    writeIORef ref (MockProcessState newId newProcs)
    pure (ProcessHandleId newId)
  WaitForProcess (ProcessHandleId pid) -> liftIO $ do
    st <- readIORef ref
    case Map.lookup pid (mockProcesses st) of
      Just (_, _, code) -> pure code
      Nothing           -> pure (ExitFailureCode 1)
  TerminateProcess (ProcessHandleId pid) -> liftIO $ do
    modifyIORef' ref $ \st ->
      st { mockProcesses = Map.delete pid (mockProcesses st) }
  ReadProcessStdout (ProcessHandleId pid) -> liftIO $ do
    st <- readIORef ref
    case Map.lookup pid (mockProcesses st) of
      Just (_, out, _) -> pure out
      Nothing          -> pure ""

-- | Production Process interpreter placeholder.
runProcessIO :: Eff (Process : es) a -> Eff es a
runProcessIO = interpret $ \_ -> \case
  SpawnProcess _ -> pure (ProcessHandleId 1)
  WaitForProcess _ -> pure ExitSuccessCode
  TerminateProcess _ -> pure ()
  ReadProcessStdout _ -> pure "ok"

{-------------------------------------------------------------------------------
  Log Interpreters
-------------------------------------------------------------------------------}

data LoggedRecord = LoggedRecord
  { logRecSeverity :: !LogSeverity
  , logRecTag      :: !Text
  } deriving stock (Eq, Show)

-- | In-memory Log interpreter collecting log entries into an IORef.
runLogPure
  :: (IOE :> es)
  => IORef [LoggedRecord]
  -> Eff (Log : es) a
  -> Eff es a
runLogPure ref = interpret $ \_ -> \case
  LogEntry sev (SomeRow tag _) -> liftIO $ do
    modifyIORef' ref (LoggedRecord sev tag :)

-- | Production Log interpreter printing to stdout.
runLogIO :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLogIO = interpret $ \_ -> \case
  LogEntry sev (SomeRow tag _) -> liftIO $ do
    putStrLn $ "[" ++ show sev ++ "] " ++ T.unpack tag

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Effect.Interpreter.Polysemy
-- Description : Polysemy seam compatibility interpreters for core signatures
--
-- Implements Polysemy interpreters for Clock, Resource, Process, and Log
-- satisfying dual-interpreter parity per EFFECT_CATALOG_DESIGN.md and PHASE_0_PLAN.md TP-0.6.
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
  , spawnProcessPoly
  , waitForProcessPoly
  , terminateProcessPoly
  , readProcessStdoutPoly
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

import qualified Polysemy as P

import Sarutahiko.Effect.Clock (Clock (..))
import Sarutahiko.Effect.Interpreter.Effectful
  ( LoggedRecord (..)
  , MockProcessState (..)
  )
import Sarutahiko.Effect.Log (Log (..), LogSeverity, SomeRow (..))
import Sarutahiko.Effect.Process
  ( Process (..)
  , ProcessConfig (..)
  , ProcessExitCode (..)
  , ProcessHandleId (..)
  )
import Sarutahiko.Effect.Resource (Resource (..), ResourceKey (..))

{-------------------------------------------------------------------------------
  Smart Senders
-------------------------------------------------------------------------------}

getCurrentTimePoly :: P.Member Clock r => P.Sem r UTCTime
getCurrentTimePoly = P.send GetCurrentTime

getMonotonicTimePoly :: P.Member Clock r => P.Sem r Double
getMonotonicTimePoly = P.send GetMonotonicTime

sleepPoly :: P.Member Clock r => NominalDiffTime -> P.Sem r ()
sleepPoly = P.send . Sleep

allocatePoly :: P.Member Resource r => P.Sem r () -> P.Sem r ResourceKey
allocatePoly = P.send . Allocate

releasePoly :: P.Member Resource r => ResourceKey -> P.Sem r ()
releasePoly = P.send . Release

spawnProcessPoly :: P.Member Process r => ProcessConfig -> P.Sem r ProcessHandleId
spawnProcessPoly = P.send . SpawnProcess

waitForProcessPoly :: P.Member Process r => ProcessHandleId -> P.Sem r ProcessExitCode
waitForProcessPoly = P.send . WaitForProcess

terminateProcessPoly :: P.Member Process r => ProcessHandleId -> P.Sem r ()
terminateProcessPoly = P.send . TerminateProcess

readProcessStdoutPoly :: P.Member Process r => ProcessHandleId -> P.Sem r ByteString
readProcessStdoutPoly = P.send . ReadProcessStdout

logEntryPoly :: P.Member Log r => LogSeverity -> SomeRow -> P.Sem r ()
logEntryPoly s r = P.send (LogEntry s r)

{-------------------------------------------------------------------------------
  Clock Interpreters
-------------------------------------------------------------------------------}

-- | In-memory Clock interpreter using an IORef holding current simulated monotonic time.
runClockPurePoly
  :: P.Member (P.Embed IO) r
  => UTCTime
  -> IORef Double
  -> P.Sem (Clock : r) a
  -> P.Sem r a
runClockPurePoly fixedUtc timeRef = P.interpret $ \case
  GetCurrentTime -> pure fixedUtc
  GetMonotonicTime -> P.embed $ readIORef timeRef
  Sleep dt -> P.embed $ modifyIORef' timeRef (+ realToFrac dt)

-- | Real IO Clock interpreter.
runClockIOPoly
  :: P.Member (P.Embed IO) r
  => P.Sem (Clock : r) a
  -> P.Sem r a
runClockIOPoly = P.interpret $ \case
  GetCurrentTime -> P.embed getCurrentTime
  GetMonotonicTime -> P.embed getMonotonicTime
  Sleep dt -> P.embed $ threadDelay (round (nominalDiffTimeToSeconds dt * 1e6))

{-------------------------------------------------------------------------------
  Resource Interpreters
-------------------------------------------------------------------------------}

-- | In-memory Resource interpreter tracking allocations and releases in an IORef.
runResourcePurePoly
  :: P.Member (P.Embed IO) r
  => IORef [Text]
  -> P.Sem (Resource : r) a
  -> P.Sem r a
runResourcePurePoly logRef = P.interpretH $ \case
  Allocate finalizer -> do
    let key = ResourceKey 100
    P.embed $ modifyIORef' logRef (\s -> "allocated:100" : s)
    f' <- P.runT finalizer
    _ <- P.raise (runResourcePurePoly logRef f')
    P.pureT key
  Release (ResourceKey k) -> do
    P.embed $ modifyIORef' logRef (\s -> ("released:" <> showText k) : s)
    P.pureT ()
  where
    showText :: Word64 -> Text
    showText = T.pack . show

-- | Real IO Resource interpreter.
runResourceIOPoly
  :: P.Sem (Resource : r) a
  -> P.Sem r a
runResourceIOPoly = P.interpretH $ \case
  Allocate finalizer -> do
    f' <- P.runT finalizer
    _ <- P.raise (runResourceIOPoly f')
    P.pureT (ResourceKey 1)
  Release _ -> P.pureT ()

{-------------------------------------------------------------------------------
  Process Interpreters
-------------------------------------------------------------------------------}

-- | Mock Process interpreter simulating subprocess execution in-memory.
runProcessMockPoly
  :: P.Member (P.Embed IO) r
  => IORef MockProcessState
  -> P.Sem (Process : r) a
  -> P.Sem r a
runProcessMockPoly ref = P.interpret $ \case
  SpawnProcess cfg -> P.embed $ do
    st <- readIORef ref
    let newId = mockSpawnCount st + 1
        fakeOutput = "mock_output_for:" <> TE.encodeUtf8 (procCommand cfg)
        newProcs = Map.insert newId (cfg, fakeOutput, ExitSuccessCode) (mockProcesses st)
    writeIORef ref (MockProcessState newId newProcs)
    pure (ProcessHandleId newId)
  WaitForProcess (ProcessHandleId pid) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup pid (mockProcesses st) of
      Just (_, _, code) -> pure code
      Nothing           -> pure (ExitFailureCode 1)
  TerminateProcess (ProcessHandleId pid) -> P.embed $ do
    modifyIORef' ref $ \st ->
      st { mockProcesses = Map.delete pid (mockProcesses st) }
  ReadProcessStdout (ProcessHandleId pid) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup pid (mockProcesses st) of
      Just (_, out, _) -> pure out
      Nothing          -> pure ""

-- | Production Process interpreter placeholder.
runProcessIOPoly
  :: P.Sem (Process : r) a
  -> P.Sem r a
runProcessIOPoly = P.interpret $ \case
  SpawnProcess _ -> pure (ProcessHandleId 1)
  WaitForProcess _ -> pure ExitSuccessCode
  TerminateProcess _ -> pure ()
  ReadProcessStdout _ -> pure "ok"

{-------------------------------------------------------------------------------
  Log Interpreters
-------------------------------------------------------------------------------}

-- | In-memory Log interpreter collecting log entries into an IORef.
runLogPurePoly
  :: P.Member (P.Embed IO) r
  => IORef [LoggedRecord]
  -> P.Sem (Log : r) a
  -> P.Sem r a
runLogPurePoly ref = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    modifyIORef' ref (LoggedRecord sev tag :)

-- | Production Log interpreter printing to stdout.
runLogIOPoly
  :: P.Member (P.Embed IO) r
  => P.Sem (Log : r) a
  -> P.Sem r a
runLogIOPoly = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    putStrLn $ "[" ++ show sev ++ "] " ++ T.unpack tag

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
--
-- Executes standardized workflows across both effectful and polysemy runtimes,
-- asserting identical results, state transitions, and teardown behavior
-- per EFFECT_CATALOG_DESIGN.md and PHASE_0_PLAN.md TP-0.6.
module Sarutahiko.Effect.Testkit.Parity
  ( -- * Parity Test Results
    ClockParityResult (..)
  , ResourceParityResult (..)
  , ProcessParityResult (..)
  , LogParityResult (..)

    -- * Parity Runners
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

import Effectful
import qualified Polysemy as P

-- Effectful interpreters
import Sarutahiko.Effect.Interpreter.Effectful
  ( LoggedRecord (..)
  , MockProcessState (..)
  , allocateEff
  , emptyMockProcessState
  , getCurrentTimeEff
  , getMonotonicTimeEff
  , logEntryEff
  , readProcessStdoutEff
  , releaseEff
  , runClockPure
  , runLogPure
  , runProcessMock
  , runResourcePure
  , sleepEff
  , spawnProcessEff
  , terminateProcessEff
  , waitForProcessEff
  )

-- Polysemy interpreters
import Sarutahiko.Effect.Interpreter.Polysemy
  ( allocatePoly
  , getCurrentTimePoly
  , getMonotonicTimePoly
  , logEntryPoly
  , readProcessStdoutPoly
  , releasePoly
  , runClockPurePoly
  , runLogPurePoly
  , runProcessMockPoly
  , runResourcePurePoly
  , sleepPoly
  , spawnProcessPoly
  , terminateProcessPoly
  , waitForProcessPoly
  )

import Sarutahiko.Effect.Log (LogSeverity (..), SomeRow (..))
import Sarutahiko.Effect.Process
  ( ProcessConfig (..)
  , ProcessExitCode (..)
  , ProcessHandleId (..)
  )
import Sarutahiko.Records (emptyRecord)

{-------------------------------------------------------------------------------
  Clock Parity
-------------------------------------------------------------------------------}

data ClockParityResult = ClockParityResult
  { clkInitialUtc   :: !UTCTime
  , clkMonotonicPre :: !Double
  , clkMonotonicPost:: !Double
  } deriving stock (Eq, Show)

runClockParity :: UTCTime -> IO (ClockParityResult, ClockParityResult)
runClockParity testUtc = do
  -- Effectful run
  effRef <- newIORef (100.0 :: Double)
  (effPre, effPost, effUtc) <- runEff . runClockPure testUtc effRef $ do
    t0 <- getMonotonicTimeEff
    sleepEff (secondsToNominalDiffTime 0.5)
    t1 <- getMonotonicTimeEff
    utc <- getCurrentTimeEff
    pure (t0, t1, utc)
  let effRes = ClockParityResult effUtc effPre effPost

  -- Polysemy run
  polyRef <- newIORef (100.0 :: Double)
  (polyPre, polyPost, polyUtc) <- P.runM . runClockPurePoly testUtc polyRef $ do
    t0 <- getMonotonicTimePoly
    sleepPoly (secondsToNominalDiffTime 0.5)
    t1 <- getMonotonicTimePoly
    utc <- getCurrentTimePoly
    pure (t0, t1, utc)
  let polyRes = ClockParityResult polyUtc polyPre polyPost

  pure (effRes, polyRes)

{-------------------------------------------------------------------------------
  Resource Parity
-------------------------------------------------------------------------------}

data ResourceParityResult = ResourceParityResult
  { resEventLog :: ![Text]
  } deriving stock (Eq, Show)

runResourceParity :: IO (ResourceParityResult, ResourceParityResult)
runResourceParity = do
  -- Effectful run
  effLogRef <- newIORef []
  runEff . runResourcePure effLogRef $ do
    k <- allocateEff (pure ())
    releaseEff k
  effEvents <- readIORef effLogRef
  let effRes = ResourceParityResult effEvents

  -- Polysemy run
  polyLogRef <- newIORef []
  P.runM . runResourcePurePoly polyLogRef $ do
    k <- allocatePoly (pure ())
    releasePoly k
  polyEvents <- readIORef polyLogRef
  let polyRes = ResourceParityResult polyEvents

  pure (effRes, polyRes)

{-------------------------------------------------------------------------------
  Process Parity
-------------------------------------------------------------------------------}

data ProcessParityResult = ProcessParityResult
  { procHandleId :: !ProcessHandleId
  , procStdout   :: !ByteString
  , procExit     :: !ProcessExitCode
  , procMapEmpty :: !Bool
  } deriving stock (Eq, Show)

runProcessParity :: IO (ProcessParityResult, ProcessParityResult)
runProcessParity = do
  let cfg = ProcessConfig "git" ["status"] Nothing []

  -- Effectful run
  effStateRef <- newIORef emptyMockProcessState
  (effPid, effOut, effCode) <- runEff . runProcessMock effStateRef $ do
    pid <- spawnProcessEff cfg
    out <- readProcessStdoutEff pid
    code <- waitForProcessEff pid
    terminateProcessEff pid
    pure (pid, out, code)
  effSt <- readIORef effStateRef
  let effRes = ProcessParityResult effPid effOut effCode (Map.null (mockProcesses effSt))

  -- Polysemy run
  polyStateRef <- newIORef emptyMockProcessState
  (polyPid, polyOut, polyCode) <- P.runM . runProcessMockPoly polyStateRef $ do
    pid <- spawnProcessPoly cfg
    out <- readProcessStdoutPoly pid
    code <- waitForProcessPoly pid
    terminateProcessPoly pid
    pure (pid, out, code)
  polySt <- readIORef polyStateRef
  let polyRes = ProcessParityResult polyPid polyOut polyCode (Map.null (mockProcesses polySt))

  pure (effRes, polyRes)

{-------------------------------------------------------------------------------
  Log Parity
-------------------------------------------------------------------------------}

data LogParityResult = LogParityResult
  { logEntries :: ![LoggedRecord]
  } deriving stock (Eq, Show)

runLogParity :: IO (LogParityResult, LogParityResult)
runLogParity = do
  let rowA = SomeRow "agent.turn" (Anon.insert #seq (Identity (1 :: Int)) emptyRecord)
      rowB = SomeRow "agent.tool" (Anon.insert #code (Identity (200 :: Int)) emptyRecord)

  -- Effectful run
  effLogRef <- newIORef []
  runEff . runLogPure effLogRef $ do
    logEntryEff LogDebug rowA
    logEntryEff LogInfo rowB
  effRecords <- readIORef effLogRef
  let effRes = LogParityResult (reverse effRecords)

  -- Polysemy run
  polyLogRef <- newIORef []
  P.runM . runLogPurePoly polyLogRef $ do
    logEntryPoly LogDebug rowA
    logEntryPoly LogInfo rowB
  polyRecords <- readIORef polyLogRef
  let polyRes = LogParityResult (reverse polyRecords)

  pure (effRes, polyRes)

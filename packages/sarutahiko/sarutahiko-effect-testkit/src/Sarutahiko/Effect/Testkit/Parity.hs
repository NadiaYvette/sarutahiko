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
  , ProcessSignal (..)
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
    killChild h SigTerm
    pure (h, out, c)
  effSt <- readIORef effRef
  let effRes = ProcessParityResult (childId effH) effOut effCode (Map.null (mockProcesses effSt))

  -- Polysemy run
  polyRef <- newIORef emptyMockProcessState
  (polyH, polyOut, polyCode) <- P.runM . runProcessMockPoly polyRef $ do
    h <- spawnChild cfg
    out <- readStdout h
    c <- waitChild h
    killChild h SigTerm
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
    logEntryEff LogInfo entry
  effEvents <- map (\r -> (logRecSeverity r, logRecTag r)) <$> readIORef effLogRef
  let effRes = LogParityResult effEvents

  polyLogRef <- newIORef []
  P.runM . runLogPurePoly polyLogRef $ do
    logEntryPoly LogInfo entry
  polyEvents <- map (\r -> (logRecSeverity r, logRecTag r)) <$> readIORef polyLogRef
  let polyRes = LogParityResult polyEvents

  pure (effRes, polyRes)

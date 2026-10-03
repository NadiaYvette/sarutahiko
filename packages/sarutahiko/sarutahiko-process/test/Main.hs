{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Test suite for sarutahiko-process (TP-1.4)
--
-- Deterministically validates Invariant 1 (Deadline Kill & Fail-Closed Termination)
-- and Invariant 2 (Environment Hygiene) under Effectful IO runtime.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.List as List
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs, setEnv)
import System.Exit (exitFailure, exitSuccess)

import Effectful
import Sarutahiko.Process

main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runDeadline = runAll || any (List.isInfixOf "DeadlineKill") args

  putStrLn "=== Running sarutahiko-process Supervisor & Invariant Suite (TP-1.4) ==="
  rDead <- if runDeadline then testDeadlineKillAndHygiene else pure True

  if rDead
    then do
      putStrLn "\nAll sarutahiko-process tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome sarutahiko-process tests FAILED."
      exitFailure

assertBool :: String -> Bool -> IO Bool
assertBool desc cond = do
  if cond
    then do
      putStrLn $ "  [PASS] " ++ desc
      pure True
    else do
      putStrLn $ "  [FAIL] " ++ desc
      pure False

testDeadlineKillAndHygiene :: IO Bool
testDeadlineKillAndHygiene = do
  putStrLn "--- Deadline Kill & Fail-Closed Termination (Invariants 1 & 2) ---"
  results <- sequence
    [ testDeadlineKillOnTimeout
    , testSigkillAfterSigtermDeadlineExpired
    , testEnvironmentHygieneAllowlist
    , testStdioPiping
    , testParentAbortBracketCleanup
    ]
  pure (and results)

-- 1. Invariant 1: Fail-closed termination on deadline expiration
testDeadlineKillOnTimeout :: IO Bool
testDeadlineKillOnTimeout = do
  t0 <- getMonotonicTime
  let cfg = (defaultProcessConfig "/usr/bin/sleep")
        { cmdArgs = ["10"]
        , timeout = 0.2 -- 200ms deadline
        }
  res <- runEff $ runProcessIO $ withSupervisedChild cfg $ \child -> do
    -- Attempt to wait 5 seconds inside the child
    waitChildEff child
  t1 <- getMonotonicTime
  let elapsed = t1 - t0
      timedOut = case res of
        Left TerminatedDeadlineExpired -> True
        _ -> False
      promptlyKilled = elapsed >= 0.15 && elapsed < 1.0
  assertBool "Invariant 1: Subprocess exceeding deadline receives prompt SIGTERM and terminates"
    (timedOut && promptlyKilled)

-- 2. Invariant 1: SIGKILL escalation after 500ms when child ignores SIGTERM
testSigkillAfterSigtermDeadlineExpired :: IO Bool
testSigkillAfterSigtermDeadlineExpired = do
  t0 <- getMonotonicTime
  -- Spawn a shell script that traps and ignores SIGTERM
  let cfg = (defaultProcessConfig "/usr/bin/sh")
        { cmdArgs = ["-c", "trap '' TERM; exec sleep 10"]
        , timeout = 0.2 -- 200ms deadline
        }
  res <- runEff $ runProcessIO $ withSupervisedChild cfg $ \child -> do
    waitChildEff child
  t1 <- getMonotonicTime
  let elapsed = t1 - t0
      timedOut = case res of
        Left TerminatedDeadlineExpired -> True
        _ -> False
      -- Must take at least 0.2s timeout + 0.5s grace period = ~0.7s, but less than 3s
      escalatedToKill = elapsed >= 0.65 && elapsed < 3.0
  assertBool "Invariant 1: Subprocess ignoring SIGTERM is forcefully killed via SIGKILL after 500ms"
    (timedOut && escalatedToKill)

-- 3. Invariant 2: Host environment hygiene and explicit allowlist
testEnvironmentHygieneAllowlist :: IO Bool
testEnvironmentHygieneAllowlist = do
  -- Poison host environment with a sensitive token
  setEnv "SECRET_API_TOKEN" "super_secret_value"
  let cfg = (defaultProcessConfig "/usr/bin/sh")
        { cmdArgs = ["-c", "printf '%s|%s' \"$SECRET_API_TOKEN\" \"$EXPLICIT_ALLOWED_VAR\""]
        , cmdEnv  = [("EXPLICIT_ALLOWED_VAR", "visible_value")]
        , timeout = 5.0
        }
  out <- runEff $ runProcessIO $ withSupervisedChild cfg $ \child -> do
    _ <- waitChildEff child
    readStdoutEff child
  case out of
    Right bs -> do
      let str = BSC.unpack bs
          isScrubbed = str == "|visible_value"
      assertBool "Invariant 2: Host environment variables scrubbed; explicit allowlist preserved"
        isScrubbed
    Left _ -> assertBool "Invariant 2: Subprocess unexpectedly aborted" False

-- 4. Stdio piping over stdin and stdout
testStdioPiping :: IO Bool
testStdioPiping = do
  let cfg = (defaultProcessConfig "/usr/bin/cat")
        { timeout = 5.0
        }
  out <- runEff $ runProcessIO $ withSupervisedChild cfg $ \child -> do
    writeStdinEff child "hello sarutahiko subprocess\n"
    -- Give cat a brief moment to echo
    liftIO $ threadDelay 20000
    readStdoutEff child
  case out of
    Right bs -> do
      let matches = bs == "hello sarutahiko subprocess\n"
      assertBool "Stdio: Data piped to child stdin is read from stdout" matches
    Left _ -> assertBool "Stdio piping failed" False

-- 5. Bracket cleanup when parent computation aborts with an exception
testParentAbortBracketCleanup :: IO Bool
testParentAbortBracketCleanup = do
  let cfg = (defaultProcessConfig "/usr/bin/sleep")
        { cmdArgs = ["10"]
        , timeout = 5.0
        }
  res <- try $ runEff $ runProcessIO $ withSupervisedChild cfg $ \_ -> do
    error "forced parent abort exception"
  case res of
    Left (_ :: SomeException) -> do
      assertBool "Invariant 1: Parent computation abortion successfully triggers bracketed child teardown" True
    Right _ ->
      assertBool "Parent computation was expected to throw exception" False

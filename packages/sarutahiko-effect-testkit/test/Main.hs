{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Clock (getCurrentTime)
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.Effect.Testkit.Parity
  ( runClockParity
  , runLogParity
  , runProcessParity
  , runResourceParity
  )

main :: IO ()
main = do
  putStrLn "=================================================================="
  putStrLn "  Sarutahiko Effect Dual-Interpreter Parity Gate (TP-0.6)"
  putStrLn "  Validating exact equivalence between effectful and polysemy"
  putStrLn "=================================================================="

  tNow <- getCurrentTime
  results <- sequence
    [ testClockParity tNow
    , testResourceParity
    , testProcessParity
    , testLogParity
    ]

  if and results
    then do
      putStrLn "\n[PASS] Dual-Interpreter Parity Gate PASSED across all signatures."
      exitSuccess
    else do
      putStrLn "\n[FAIL] Dual-Interpreter Parity Gate FAILED."
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

testClockParity :: tNow -> IO Bool
testClockParity _ = do
  tNow <- getCurrentTime
  (effRes, polyRes) <- runClockParity tNow
  assertBool "Clock Parity: effectful and polysemy produce identical monotonic and UTC timestamps"
             (effRes == polyRes)

testResourceParity :: IO Bool
testResourceParity = do
  (effRes, polyRes) <- runResourceParity
  assertBool "Resource Parity: effectful and polysemy produce identical allocation/cleanup traces"
             (effRes == polyRes)

testProcessParity :: IO Bool
testProcessParity = do
  (effRes, polyRes) <- runProcessParity
  assertBool "Process Parity: effectful and polysemy produce identical stdout, exit code, and teardown"
             (effRes == polyRes)

testLogParity :: IO Bool
testLogParity = do
  (effRes, polyRes) <- runLogParity
  assertBool "Log Parity: effectful and polysemy produce identical structured telemetry entries"
             (effRes == polyRes)

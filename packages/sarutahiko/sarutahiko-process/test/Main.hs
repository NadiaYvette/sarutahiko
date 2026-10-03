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
  _out <- readStdoutIO pt h
  code <- waitChildIO pt h
  closeChildHandlesIO pt h
  unless (code == ExitSuccess) $ do
    putStrLn $ "Expected ExitSuccess, got: " ++ show code
    exitFailure
  putStrLn "  [PASS] Subprocess spawned and waited successfully."
  exitSuccess

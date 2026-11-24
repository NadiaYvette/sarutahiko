{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text.IO as TIO
import Kogaki.QA (detectRawEscapes)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--check-escapes", path] -> do
      content <- TIO.readFile path
      case detectRawEscapes content of
        [] -> do
          putStrLn $ "kogaki-qa: " ++ path ++ " clean (no raw escapes)"
          exitSuccess
        viols -> do
          putStrLn $ "kogaki-qa: violations in " ++ path ++ ":"
          mapM_ (putStrLn . ("  " ++) . show) viols
          exitFailure
    _ -> do
      putStrLn "Usage: kogaki-qa --check-escapes <file.ftl>"
      exitSuccess

{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>), takeExtension)

import Sarutahiko.Tags

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--help"] -> printHelp >> exitSuccess
    ["-h"]     -> printHelp >> exitSuccess
    ["--json", path] -> do
      tags <- collectTags path
      BSC.putStrLn (formatTagsJsonLines tags)
    [path] -> do
      tags <- collectTags path
      BSC.putStrLn (formatTagsFile tags)
    _ -> do
      putStrLn "Usage: sarutahiko-tags [--json] <file-or-dir>"
      exitFailure

printHelp :: IO ()
printHelp = do
  putStrLn "sarutahiko-tags — Fast scope-stack symbol tag extractor"
  putStrLn ""
  putStrLn "Usage:"
  putStrLn "  sarutahiko-tags <path>         Output traditional Vi/Ex tags"
  putStrLn "  sarutahiko-tags --json <path>  Output Universal Ctags JSON Lines"

collectTags :: FilePath -> IO [TagEntry]
collectTags path = do
  isDir <- doesDirectoryExist path
  if isDir
    then do
      files <- listFilesRecursive path
      fmap concat (mapM processFile files)
    else do
      isFile <- doesFileExist path
      if isFile
        then processFile path
        else pure []

processFile :: FilePath -> IO [TagEntry]
processFile fp = do
  let ext = takeExtension fp
  if ext `elem` [".hs", ".lhs", ".c", ".h", ".cpp"]
    then do
      content <- TIO.readFile fp
      pure (extractTagsFromSource fp content)
    else pure []

listFilesRecursive :: FilePath -> IO [FilePath]
listFilesRecursive dir = do
  entries <- listDirectory dir
  fmap concat $ for entries $ \entry -> do
    let full = dir </> entry
    isD <- doesDirectoryExist full
    if isD
      then if entry `elem` [".git", "dist-newstyle", ".yamaarashi"]
             then pure []
             else listFilesRecursive full
      else pure [full]
  where
    for = flip mapM

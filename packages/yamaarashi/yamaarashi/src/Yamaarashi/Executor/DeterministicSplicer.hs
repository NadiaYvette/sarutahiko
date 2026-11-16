{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module      : Yamaarashi.Executor.DeterministicSplicer
-- Description : Pre-Staged Code Seed Mounting & Diff-Free Symbol Splicing
--
-- Deterministic execution utilities for task packets:
-- 1. Mounts pre-staged verified code seeds from attachments directly into worktrees.
-- 2. Evaluates zero-turn pre-checks (hls-autoheal + verification commands) without LLM calls.
-- 3. Splices top-level declaration blocks cleanly without unified diff parsers.
module Yamaarashi.Executor.DeterministicSplicer
  ( -- * Configuration & Seed Mounts
    SplicerConfig (..)
  , SeedMount (..)
  , defaultSplicerConfig

    -- * Seed Mounting
  , mountPrestageSeeds

    -- * AST Declaration Splicing
  , spliceTopLevelDeclaration

    -- * Zero-Turn Pre-Check
  , runZeroTurnCheck
  ) where

import Control.Monad (forM_)
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process
  ( CreateProcess (..)
  , readCreateProcessWithExitCode
  , shell
  )

-- | Configuration for seed mounting and worktree splicing.
data SplicerConfig = SplicerConfig
  { manifestPath :: !FilePath
  , seedsDir     :: !FilePath
  , worktreeDir  :: !FilePath
  } deriving stock (Show, Eq)

-- | Default configuration pointing to the Ingolstadt seed manifest.
defaultSplicerConfig :: FilePath -> SplicerConfig
defaultSplicerConfig wt = SplicerConfig
  { manifestPath = "campaigns/prestage-seeds-ingolstadt.dhall"
  , seedsDir     = "/home/nyc/src/plans/seeds"
  , worktreeDir  = wt
  }

-- | A pre-staged seed attachment to be materialized in the target worktree.
data SeedMount = SeedMount
  { targetRelativePath :: !FilePath
  , seedPayload        :: !Text
  } deriving stock (Show, Eq)

-- | Materializes pre-staged seed attachments into the target worktree.
mountPrestageSeeds :: FilePath -> [SeedMount] -> IO ()
mountPrestageSeeds wtDir seeds =
  forM_ seeds $ \sm -> do
    let fullPath = wtDir </> targetRelativePath sm
    createDirectoryIfMissing True (takeDirectory fullPath)
    TIO.writeFile fullPath (seedPayload sm)

-- | Replaces or appends a top-level declaration block for a given symbol name.
spliceTopLevelDeclaration :: FilePath -> Text -> Text -> IO ()
spliceTopLevelDeclaration fp symName newDecl = do
  exists <- doesFileExist fp
  if not exists
    then do
      createDirectoryIfMissing True (takeDirectory fp)
      TIO.writeFile fp newDecl
    else do
      content <- TIO.readFile fp
      let ls = T.lines content
          mSpan = findDeclSpan symName ls
      case mSpan of
        Nothing -> do
          let updated = content <> "\n\n" <> newDecl <> "\n"
          TIO.writeFile fp updated
        Just (startIdx, endIdx) -> do
          let before = take startIdx ls
              after = drop endIdx ls
              newLines = T.lines newDecl
              updated = T.unlines (before ++ newLines ++ after)
          TIO.writeFile fp updated

findDeclSpan :: Text -> [Text] -> Maybe (Int, Int)
findDeclSpan sym ls =
  case [i | (i, l) <- zip [0..] ls, isTopLevelDef sym l] of
    [] -> Nothing
    (startIdx:_) ->
      let rest = zip [startIdx + 1 ..] (drop (startIdx + 1) ls)
          endIdx = case [i | (i, l) <- rest, isNextTopLevelFor sym l] of
            (nextTop:_) -> nextTop
            []          -> length ls
       in Just (startIdx, endIdx)

isTopLevelDef :: Text -> Text -> Bool
isTopLevelDef sym line =
  let t = T.stripStart line
   in not (T.null t)
        && not ("--" `T.isPrefixOf` t)
        && not (isLeadingSpace line)
        && (sym `T.isPrefixOf` line)
        && (let remText = T.drop (T.length sym) line
             in T.null remText || T.isPrefixOf " " remText || T.isPrefixOf "\t" remText || T.isPrefixOf "::" remText)

isLeadingSpace :: Text -> Bool
isLeadingSpace t = case T.uncons t of
  Just (c, _) -> isSpace c
  Nothing     -> False

isNextTopLevelFor :: Text -> Text -> Bool
isNextTopLevelFor sym line =
  let stripped = T.strip line
   in not (T.null stripped)
        && not ("--" `T.isPrefixOf` stripped)
        && not (isLeadingSpace line)
        && not (isTopLevelDef sym line)

-- | Runs automated repair (hls-autoheal) and executes the verification command.
-- Returns True if the gate passes without needing any LLM turns.
runZeroTurnCheck :: FilePath -> String -> IO Bool
runZeroTurnCheck wtDir verifyCmd = do
  let autohealCp = (shell "command -v hls-autoheal >/dev/null 2>&1 && hls-autoheal || true")
        { cwd = Just wtDir }
  _ <- readCreateProcessWithExitCode autohealCp ""
  let verifyCp = (shell verifyCmd) { cwd = Just wtDir }
  (ec, _, _) <- readCreateProcessWithExitCode verifyCp ""
  pure (ec == ExitSuccess)

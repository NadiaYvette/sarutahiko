#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-015D] Implementing Yamaarashi.Executor.DeterministicSplicer ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Executor

cat << 'EOF' > packages/yamaarashi/yamaarashi/src/Yamaarashi/Executor/DeterministicSplicer.hs
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
EOF

echo "=== [TP-015D] Updating yamaarashi.cabal and Spec.hs ==="
python3 -c '
# 1. Update yamaarashi.cabal
with open("packages/yamaarashi/yamaarashi/yamaarashi.cabal", "r") as f:
    cabal = f.read()

if "Yamaarashi.Executor.DeterministicSplicer" not in cabal:
    cabal = cabal.replace(
        "        Yamaarashi.Sandbox.Airgap",
        "        Yamaarashi.Sandbox.Airgap\n        Yamaarashi.Executor.DeterministicSplicer"
    )

with open("packages/yamaarashi/yamaarashi/yamaarashi.cabal", "w") as f:
    f.write(cabal)

# 2. Update Spec.hs
with open("packages/yamaarashi/yamaarashi/test/Spec.hs", "r") as f:
    spec = f.read()

import_snippet = """import qualified Data.Text.IO as TIO
import qualified System.CPUTime as CPUTime
import System.FilePath ((</>))
import qualified Yamaarashi.Executor.DeterministicSplicer as Splicer
"""

if "Yamaarashi.Executor.DeterministicSplicer" not in spec:
    spec = spec.replace(
        "import qualified Yamaarashi.Sandbox.Airgap as Airgap\n",
        "import qualified Yamaarashi.Sandbox.Airgap as Airgap\n" + import_snippet
    )

    test_group = """  , testGroup "Yamaarashi.Executor.DeterministicSplicer"
      [ testProperty "mountPrestageSeeds writes files to target relative paths" prop_splicer_mount
      , testProperty "spliceTopLevelDeclaration replaces function declaration cleanly" prop_splicer_splice
      , testProperty "spliceTopLevelDeclaration appends missing function declaration" prop_splicer_splice_append
      , testProperty "runZeroTurnCheck validates verification command exit code" prop_splicer_zero_turn
      ]
  ]"""

    spec = spec.replace(
        """  , testGroup "Yamaarashi.Sandbox.Airgap"
      [ testProperty "creates isolated home and masks credential paths" prop_airgap_isolated_home
      , testProperty "scrubs API keys, secrets, and cloud variables from environment" prop_airgap_scrubbed_env
      , testProperty "executes subprocess reactively in isolated sandbox" prop_airgap_run_isolated
      ]
  ]""",
        """  , testGroup "Yamaarashi.Sandbox.Airgap"
      [ testProperty "creates isolated home and masks credential paths" prop_airgap_isolated_home
      , testProperty "scrubs API keys, secrets, and cloud variables from environment" prop_airgap_scrubbed_env
      , testProperty "executes subprocess reactively in isolated sandbox" prop_airgap_run_isolated
      ]
""" + test_group
    )

    properties = r"""
--------------------------------------------------------------------------------
-- DeterministicSplicer Tests
--------------------------------------------------------------------------------

prop_splicer_mount :: Property
prop_splicer_mount = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-test-" ++ show t)
      mount1 = Splicer.SeedMount "src/Foo/Bar.hs" "module Foo.Bar where\nx = 42\n"
      mount2 = Splicer.SeedMount "README.txt" "Seed documentation\n"
  evalIO $ Splicer.mountPrestageSeeds testDir [mount1, mount2]
  f1Exists <- evalIO $ Directory.doesFileExist (testDir </> "src/Foo/Bar.hs")
  f2Exists <- evalIO $ Directory.doesFileExist (testDir </> "README.txt")
  f1Exists === True
  f2Exists === True
  c1 <- evalIO $ TIO.readFile (testDir </> "src/Foo/Bar.hs")
  c1 === "module Foo.Bar where\nx = 42\n"

prop_splicer_splice :: Property
prop_splicer_splice = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-splice-" ++ show t)
      testFile = testDir </> "Target.hs"
      initial = T.unlines
        [ "module Target where"
        , ""
        , "oldFunc :: Int -> Int"
        , "oldFunc x ="
        , "  x + 1"
        , ""
        , "otherFunc :: Bool"
        , "otherFunc = True"
        ]
      replacement = T.unlines
        [ "oldFunc :: Int -> Int"
        , "oldFunc x = x * 10"
        ]
  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ TIO.writeFile testFile initial
  evalIO $ Splicer.spliceTopLevelDeclaration testFile "oldFunc" (T.stripEnd replacement)
  content <- evalIO $ TIO.readFile testFile
  assert (T.isInfixOf "oldFunc x = x * 10" content)
  assert (not (T.isInfixOf "x + 1" content))
  assert (T.isInfixOf "otherFunc = True" content)

prop_splicer_splice_append :: Property
prop_splicer_splice_append = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-append-" ++ show t)
      testFile = testDir </> "Target.hs"
      initial = "module Target where\n\nexisting = 1\n"
      newDecl = "addedFunc :: String\naddedFunc = \"hello\""
  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ TIO.writeFile testFile initial
  evalIO $ Splicer.spliceTopLevelDeclaration testFile "addedFunc" newDecl
  content <- evalIO $ TIO.readFile testFile
  assert (T.isInfixOf "existing = 1" content)
  assert (T.isInfixOf "addedFunc = \"hello\"" content)

prop_splicer_zero_turn :: Property
prop_splicer_zero_turn = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  passResult <- evalIO $ Splicer.runZeroTurnCheck tmpRoot "true"
  failResult <- evalIO $ Splicer.runZeroTurnCheck tmpRoot "false"
  passResult === True
  failResult === False
"""
    spec = spec + properties

with open("packages/yamaarashi/yamaarashi/test/Spec.hs", "w") as f:
    f.write(spec)
print("Updated yamaarashi.cabal and Spec.hs for TP-015D successfully")
'

echo "=== [TP-015D] Implementation complete ==="

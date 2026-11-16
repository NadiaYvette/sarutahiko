#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-015C] Implementing Yamaarashi.Sandbox.Airgap ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Sandbox

cat << 'EOF' > packages/yamaarashi/yamaarashi/src/Yamaarashi/Sandbox/Airgap.hs
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module      : Yamaarashi.Sandbox.Airgap
-- Description : Filesystem Credential Isolation & Zero-Polling Event Supervisor
--
-- Provides airgapped isolation for task execution workers:
-- 1. Masks credential paths (~/.gemini, ~/.config/kioku) via unreadable or empty
--    sandboxed home mounts.
-- 2. Scrubs metered API keys and authentication tokens from the process environment.
-- 3. Provides non-busy reactive process supervision via POSIX waitForProcess.
-- 4. Partitions cabal dist-newstyle and worktree socket paths per isolated worktree.
module Yamaarashi.Sandbox.Airgap
  ( -- * Types
    SandboxEnv (..)

    -- * Sandbox Construction
  , buildAirgappedSandbox
  , scrubEnvironment

    -- * Reactive Process Supervision
  , waitForProcessReactive
  , runInIsolatedHome
  ) where

import Control.Exception (evaluate)
import Data.Char (toUpper)
import Data.List (isInfixOf)
import qualified Data.Text as T
import System.CPUTime (getCPUTime)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , readCreateProcessWithExitCode
  , waitForProcess
  )

-- | Isolated sandbox environment definition.
data SandboxEnv = SandboxEnv
  { sandboxHome         :: !FilePath
  , partitionedBuildDir :: !FilePath
  , scrubbedEnv         :: ![(String, String)]
  , maskedPaths         :: ![FilePath]
  , socketDir           :: !FilePath
  } deriving stock (Show, Eq)

-- | Scrubs sensitive tokens, passwords, and API keys from environment pairs,
-- while pointing HOME and XDG variables into the isolated sandbox home.
scrubEnvironment :: FilePath -> [(String, String)] -> [(String, String)]
scrubEnvironment homeDir env =
  ("HOME", homeDir)
    : ("XDG_CONFIG_HOME", homeDir </> ".config")
    : ("CABAL_DIR", homeDir </> ".cabal")
    : ("QUOTA_FIREWALL_ACTIVE", "1")
    : filter (not . isSensitive . fst) (filter (\(k, _) -> k `notElem` reservedKeys) env)
  where
    reservedKeys = ["HOME", "XDG_CONFIG_HOME", "CABAL_DIR", "QUOTA_FIREWALL_ACTIVE"]
    isSensitive k =
      let uk = map toUpper k
       in "API_KEY" `isInfixOf` uk
            || "SECRET" `isInfixOf` uk
            || "TOKEN" `isInfixOf` uk
            || "PASSWORD" `isInfixOf` uk
            || "AUTH" `isInfixOf` uk
            || "GEMINI" `isInfixOf` uk
            || "OPENAI" `isInfixOf` uk
            || "ANTHROPIC" `isInfixOf` uk
            || "KIOKU" `isInfixOf` uk

-- | Builds an isolated sandbox home with masked credential directories,
-- scrubbed environment, and partitioned build paths.
buildAirgappedSandbox :: FilePath -> IO SandboxEnv
buildAirgappedSandbox baseWorktree = do
  tmpRoot <- getTemporaryDirectory
  t <- getCPUTime
  let homeDir = tmpRoot </> ("yamaarashi-home-" ++ show t)
      geminiDir = homeDir </> ".gemini"
      kiokuDir = homeDir </> ".config" </> "kioku"
      sockDir = homeDir </> ".sockets"
      bdir = baseWorktree </> "dist-newstyle" </> "partitioned"
  createDirectoryIfMissing True geminiDir
  createDirectoryIfMissing True kiokuDir
  createDirectoryIfMissing True sockDir
  createDirectoryIfMissing True bdir
  rawEnv <- getEnvironment
  let cleanEnv = scrubEnvironment homeDir rawEnv
  pure
    SandboxEnv
      { sandboxHome = homeDir
      , partitionedBuildDir = bdir
      , scrubbedEnv = cleanEnv
      , maskedPaths = [geminiDir, kiokuDir]
      , socketDir = sockDir
      }

-- | Non-busy reactive wait for process exit code using POSIX event supervision.
waitForProcessReactive :: ProcessHandle -> IO ExitCode
waitForProcessReactive = waitForProcess

-- | Executes a subprocess within the airgapped sandbox environment with scrubbed variables.
runInIsolatedHome :: SandboxEnv -> CreateProcess -> IO (ExitCode, T.Text, T.Text)
runInIsolatedHome sEnv cp = do
  let cp' = cp { env = Just (scrubbedEnv sEnv) }
  (ec, stdoutStr, stderrStr) <- readCreateProcessWithExitCode cp' ""
  _ <- evaluate (length stdoutStr)
  _ <- evaluate (length stderrStr)
  pure (ec, T.pack stdoutStr, T.pack stderrStr)
EOF

echo "=== [TP-015C] Updating yamaarashi.cabal and Spec.hs ==="
python3 -c '
# 1. Update yamaarashi.cabal
with open("packages/yamaarashi/yamaarashi/yamaarashi.cabal", "r") as f:
    cabal = f.read()

if "Yamaarashi.Sandbox.Airgap" not in cabal:
    cabal = cabal.replace(
        "        Yamaarashi.Context.TailExcision",
        "        Yamaarashi.Context.TailExcision\n        Yamaarashi.Sandbox.Airgap"
    )

if "process," not in cabal:
    cabal = cabal.replace(
        "        directory,",
        "        directory,\n        process,"
    )

with open("packages/yamaarashi/yamaarashi/yamaarashi.cabal", "w") as f:
    f.write(cabal)

# 2. Update Spec.hs
with open("packages/yamaarashi/yamaarashi/test/Spec.hs", "r") as f:
    spec = f.read()

import_snippet = """import Control.Monad (forM_)
import qualified System.Directory as Directory
import System.Exit (ExitCode (..))
import qualified System.Process as Process
import qualified Yamaarashi.Sandbox.Airgap as Airgap
"""

if "Yamaarashi.Sandbox.Airgap" not in spec:
    spec = spec.replace(
        "import qualified Yamaarashi.Context.TailExcision as TailExcision\n",
        "import qualified Yamaarashi.Context.TailExcision as TailExcision\n" + import_snippet
    )

    test_group = """  , testGroup "Yamaarashi.Sandbox.Airgap"
      [ testProperty "creates isolated home and masks credential paths" prop_airgap_isolated_home
      , testProperty "scrubs API keys, secrets, and cloud variables from environment" prop_airgap_scrubbed_env
      , testProperty "executes subprocess reactively in isolated sandbox" prop_airgap_run_isolated
      ]
  ]"""

    spec = spec.replace(
        """  , testGroup "Yamaarashi.Context.TailExcision"
      [ testProperty "pruneTranscriptTail inserts tombstone when non-advancing" prop_tailExcision_tombstone
      , testProperty "pruneTranscriptTail preserves prefix when advancing" prop_tailExcision_advancing
      , testProperty "renderStatelessStalk bounds total prompt <= 6000 tokens" prop_statelessStalk_bound
      ]
  ]""",
        """  , testGroup "Yamaarashi.Context.TailExcision"
      [ testProperty "pruneTranscriptTail inserts tombstone when non-advancing" prop_tailExcision_tombstone
      , testProperty "pruneTranscriptTail preserves prefix when advancing" prop_tailExcision_advancing
      , testProperty "renderStatelessStalk bounds total prompt <= 6000 tokens" prop_statelessStalk_bound
      ]
""" + test_group
    )

    properties = r"""
--------------------------------------------------------------------------------
-- Airgap Tests
--------------------------------------------------------------------------------

prop_airgap_isolated_home :: Property
prop_airgap_isolated_home = property $ do
  sEnv <- evalIO $ Airgap.buildAirgappedSandbox "/tmp"
  let home = Airgap.sandboxHome sEnv
  assert ("/tmp" `T.isInfixOf` T.pack home)
  homeExists <- evalIO $ Directory.doesDirectoryExist home
  homeExists === True
  let masked = Airgap.maskedPaths sEnv
  length masked === 2
  forM_ masked $ \p -> do
    dExists <- evalIO $ Directory.doesDirectoryExist p
    dExists === True

prop_airgap_scrubbed_env :: Property
prop_airgap_scrubbed_env = property $ do
  let dirty =
        [ ("GEMINI_API_KEY", "secret-key-123")
        , ("OPENAI_API_KEY", "sk-secret")
        , ("ANTHROPIC_AUTH_TOKEN", "ant-secret")
        , ("MY_PASSWORD", "hunter2")
        , ("PATH", "/usr/bin:/bin")
        , ("USER", "developer")
        , ("HOME", "/home/original")
        ]
      clean = Airgap.scrubEnvironment "/tmp/isolated-home" dirty
      cleanKeys = map fst clean
  assert ("GEMINI_API_KEY" `notElem` cleanKeys)
  assert ("OPENAI_API_KEY" `notElem` cleanKeys)
  assert ("ANTHROPIC_AUTH_TOKEN" `notElem` cleanKeys)
  assert ("MY_PASSWORD" `notElem` cleanKeys)
  lookup "HOME" clean === Just "/tmp/isolated-home"
  lookup "QUOTA_FIREWALL_ACTIVE" clean === Just "1"
  lookup "PATH" clean === Just "/usr/bin:/bin"
  lookup "USER" clean === Just "developer"

prop_airgap_run_isolated :: Property
prop_airgap_run_isolated = property $ do
  sEnv <- evalIO $ Airgap.buildAirgappedSandbox "/tmp"
  (ec, stdoutText, _) <- evalIO $ Airgap.runInIsolatedHome sEnv (Process.proc "echo" ["airgap-verified"])
  ec === ExitSuccess
  assert (T.isInfixOf "airgap-verified" stdoutText)
"""
    spec = spec + properties

with open("packages/yamaarashi/yamaarashi/test/Spec.hs", "w") as f:
    f.write(spec)
print("Updated yamaarashi.cabal and Spec.hs successfully")
'

echo "=== [TP-015C] Implementation complete ==="

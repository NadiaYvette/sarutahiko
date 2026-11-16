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

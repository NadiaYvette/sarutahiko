{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Effect.Process
-- Description : Neutral subprocess execution and supervision effect GADT
--
-- Exposes subprocess lifecycle operations per EFFECT_CATALOG_DESIGN.md.
-- Conforms to DECISION-002: strictly zero concrete effect system dependencies.
module Sarutahiko.Effect.Process
  ( -- * Configuration
    ProcessConfig (..)
  , defaultProcessConfig
  , defaultEnvAllowlist

    -- * Signals and Handles
  , ProcessSignal (..)
  , ChildProcessId (..)
  , ChildHandle (..)
  , ProcessTerminationReason (..)

    -- * Effect GADT
  , Process (..)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime)
import Data.Word (Word64)
import System.Exit (ExitCode)

-- | Configuration parameters for launching and supervising a child process.
data ProcessConfig = ProcessConfig
  { cmdPath :: !FilePath           -- ^ Executable path on filesystem
  , cmdArgs :: ![Text]             -- ^ Command-line arguments
  , cmdEnv  :: ![(Text, Text)]     -- ^ Explicit environment variables to inject
  , cmdCwd  :: !(Maybe FilePath)   -- ^ Optional working directory
  , timeout :: !NominalDiffTime    -- ^ Maximum execution deadline before SIGTERM/SIGKILL
  } deriving stock (Eq, Show)

-- | Construct a default 'ProcessConfig' with a 30-second timeout.
defaultProcessConfig :: FilePath -> ProcessConfig
defaultProcessConfig fp = ProcessConfig
  { cmdPath = fp
  , cmdArgs = []
  , cmdEnv  = []
  , cmdCwd  = Nothing
  , timeout = 30
  }

-- | Default host environment variable allowlist for child execution hygiene.
defaultEnvAllowlist :: [Text]
defaultEnvAllowlist =
  [ "PATH"
  , "TERM"
  , "LANG"
  , "LC_ALL"
  , "USER"
  , "HOME"
  , "TMPDIR"
  , "SHELL"
  , "TZ"
  ]

-- | POSIX signals for terminating child processes.
data ProcessSignal
  = SigTerm
  | SigKill
  deriving stock (Eq, Show)

-- | Unique identifier for an active child process.
newtype ChildProcessId = ChildProcessId { unChildProcessId :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | Handle referencing an active child process managed by the supervisor.
data ChildHandle = ChildHandle
  { childId     :: !ChildProcessId
  , childConfig :: !ProcessConfig
  } deriving stock (Eq, Show)

-- | Outcome reason for subprocess supervision.
data ProcessTerminationReason
  = TerminatedExit !ExitCode
  | TerminatedDeadlineExpired
  | TerminatedKilled !ProcessSignal
  | TerminatedAborted !Text
  deriving stock (Eq, Show)

-- | Subprocess lifecycle effect GADT.
data Process (m :: Type -> Type) :: Type -> Type where
  SpawnChild        :: !ProcessConfig -> Process m ChildHandle
  ReadStdout        :: !ChildHandle -> Process m ByteString
  WriteStdin        :: !ChildHandle -> !ByteString -> Process m ()
  WaitChild         :: !ChildHandle -> Process m ExitCode
  PollChild         :: !ChildHandle -> Process m (Maybe ExitCode)
  KillChild         :: !ChildHandle -> !ProcessSignal -> Process m ()
  CloseChildHandles :: !ChildHandle -> Process m ()

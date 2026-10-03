{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Sarutahiko.Process.Signature
-- Description : Subprocess execution and supervision effect signature
--
-- Defines the neutral Process effect GADT, process configuration,
-- signals, and smart senders per TP-1.4 and Closure 4.
module Sarutahiko.Process.Signature
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

    -- * Smart Senders
  , spawnChildEff
  , readStdoutEff
  , writeStdinEff
  , waitChildEff
  , pollChildEff
  , killChildEff
  , closeChildHandlesEff
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime)
import Data.Word (Word64)
import System.Exit (ExitCode)

import Effectful
import Effectful.Dispatch.Dynamic

-- | Configuration parameters for launching and supervising a child process.
--
-- @since 0.1.0.0
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
-- Any host environment variable not present in this list is scrubbed.
--
-- @since 0.1.0.0
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
--
-- @since 0.1.0.0
data ProcessSignal
  = SigTerm
  | SigKill
  deriving stock (Eq, Show)

-- | Unique identifier for an active child process.
newtype ChildProcessId = ChildProcessId { unChildProcessId :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | Handle referencing an active child process managed by the supervisor.
--
-- @since 0.1.0.0
data ChildHandle = ChildHandle
  { childId     :: !ChildProcessId
  , childConfig :: !ProcessConfig
  } deriving stock (Eq, Show)

-- | Outcome reason for subprocess supervision.
--
-- @since 0.1.0.0
data ProcessTerminationReason
  = TerminatedExit !ExitCode
  | TerminatedDeadlineExpired
  | TerminatedKilled !ProcessSignal
  | TerminatedAborted !Text
  deriving stock (Eq, Show)

-- | Subprocess lifecycle effect GADT.
--
-- @since 0.1.0.0
data Process (m :: Type -> Type) :: Type -> Type where
  SpawnChild :: !ProcessConfig -> Process m ChildHandle
  ReadStdout :: !ChildHandle -> Process m ByteString
  WriteStdin :: !ChildHandle -> !ByteString -> Process m ()
  WaitChild  :: !ChildHandle -> Process m ExitCode
  PollChild  :: !ChildHandle -> Process m (Maybe ExitCode)
  KillChild  :: !ChildHandle -> !ProcessSignal -> Process m ()
  CloseChildHandles :: !ChildHandle -> Process m ()

type instance DispatchOf Process = Dynamic

-- ----------------------------------------------------------------------------
-- Smart Senders
-- ----------------------------------------------------------------------------

-- | Spawn a child process under the 'Process' effect.
spawnChildEff :: (Process :> es) => ProcessConfig -> Eff es ChildHandle
spawnChildEff = send . SpawnChild

-- | Read available output from a child process stdout pipe.
readStdoutEff :: (Process :> es) => ChildHandle -> Eff es ByteString
readStdoutEff = send . ReadStdout

-- | Write raw bytes to a child process stdin pipe.
writeStdinEff :: (Process :> es) => ChildHandle -> ByteString -> Eff es ()
writeStdinEff h bs = send (WriteStdin h bs)

-- | Block until a child process exits and retrieve its exit code.
waitChildEff :: (Process :> es) => ChildHandle -> Eff es ExitCode
waitChildEff = send . WaitChild

-- | Check whether a child process has exited without blocking.
pollChildEff :: (Process :> es) => ChildHandle -> Eff es (Maybe ExitCode)
pollChildEff = send . PollChild

-- | Send a POSIX signal to an active child process.
killChildEff :: (Process :> es) => ChildHandle -> ProcessSignal -> Eff es ()
killChildEff h sig = send (KillChild h sig)

-- | Close all open stdio handles associated with a child process.
closeChildHandlesEff :: (Process :> es) => ChildHandle -> Eff es ()
closeChildHandlesEff = send . CloseChildHandles

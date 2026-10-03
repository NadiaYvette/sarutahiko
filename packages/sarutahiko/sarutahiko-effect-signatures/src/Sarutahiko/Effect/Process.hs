{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.Process
-- Description : Subprocess invocation effect for MCP children and CLI tools
--
-- Exposes process lifecycle operations per EFFECT_CATALOG_DESIGN.md.
module Sarutahiko.Effect.Process
  ( ProcessConfig (..)
  , ProcessHandleId (..)
  , ProcessExitCode (..)
  , Process (..)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Word (Word64)

-- | Configuration parameters for launching an external process.
data ProcessConfig = ProcessConfig
  { procCommand :: !Text
  , procArgs    :: ![Text]
  , procStdin   :: !(Maybe ByteString)
  , procEnv     :: ![(Text, Text)]
  } deriving stock (Eq, Show)

-- | Abstract handle identifying an active subprocess.
newtype ProcessHandleId = ProcessHandleId { unProcessHandleId :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | Exit status returned upon subprocess termination.
data ProcessExitCode
  = ExitSuccessCode
  | ExitFailureCode !Int
  deriving stock (Eq, Show)

-- | Subprocess execution effect.
data Process (m :: Type -> Type) :: Type -> Type where
  SpawnProcess      :: !ProcessConfig -> Process m ProcessHandleId
  WaitForProcess    :: !ProcessHandleId -> Process m ProcessExitCode
  TerminateProcess  :: !ProcessHandleId -> Process m ()
  ReadProcessStdout :: !ProcessHandleId -> Process m ByteString

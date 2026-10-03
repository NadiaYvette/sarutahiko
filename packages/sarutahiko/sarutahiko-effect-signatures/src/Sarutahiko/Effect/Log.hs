{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.Log
-- Description : Structured telemetry logging with SomeRow packaging
--
-- Exposes structured logging carrying existentially packaged records
-- per EFFECT_CATALOG_DESIGN.md §6.4.
module Sarutahiko.Effect.Log
  ( LogSeverity (..)
  , SomeRow (..)
  , Log (..)
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.Text (Text)

import Sarutahiko.Records (KnownFields, Record)

-- | Severity levels for structured telemetry logs.
data LogSeverity
  = LogDebug
  | LogInfo
  | LogWarn
  | LogError
  | LogFatal
  deriving stock (Eq, Ord, Show, Read)

-- | Existential packaging for a record value per EFFECT_CATALOG_DESIGN.md §6.4.
--
-- Prevents concrete row schemas from altering ambient effect constraints at log sites.
data SomeRow where
  SomeRow
    :: forall r. (KnownFields r)
    => !Text                -- ^ Schema or namespace tag
    -> !(Record Identity r) -- ^ Strongly typed record
    -> SomeRow

-- | Structured telemetry logging effect.
data Log (m :: Type -> Type) :: Type -> Type where
  LogEntry :: !LogSeverity -> !SomeRow -> Log m ()

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.Clock
-- Description : Monotonic time and sleep effect
--
-- Exposes monotonic clock queries, calendar timestamps, and sleeps for
-- timeouts, benchmark harnesses, and latency telemetry per EFFECT_CATALOG_DESIGN.md.
module Sarutahiko.Effect.Clock
  ( Clock (..)
  ) where

import Data.Kind (Type)
import Data.Time.Clock (NominalDiffTime, UTCTime)

-- | Monotonic and calendar time effect.
data Clock (m :: Type -> Type) :: Type -> Type where
  GetCurrentTime   :: Clock m UTCTime
  GetMonotonicTime :: Clock m Double           -- ^ Monotonic time in seconds
  Sleep            :: !NominalDiffTime -> Clock m ()

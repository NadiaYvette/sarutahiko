{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.Resource
-- Description : Scoped and Resource effects for deterministic bracketed regions
--
-- Unifies resource brackets, transaction boundaries, and cursor lifetimes
-- into canonical GADT signatures per EFFECT_CATALOG_DESIGN.md §6.3.
module Sarutahiko.Effect.Resource
  ( ResourceKey (..)
  , Resource (..)
  , Scoped (..)
  ) where

import Data.Kind (Type)
import Data.Word (Word64)

-- | Unique key identifying an active allocated resource in a region.
newtype ResourceKey = ResourceKey { unResourceKey :: Word64 }
  deriving stock (Eq, Ord, Show)

-- | First-order resource effect for explicit allocation and cleanup.
data Resource (m :: Type -> Type) :: Type -> Type where
  Allocate :: m () -> Resource m ResourceKey
  Release  :: !ResourceKey -> Resource m ()

-- | The canonical higher-order Scoped pattern per EFFECT_CATALOG_DESIGN.md §6.3.
--
-- Guarantees that the finalizer runs exactly once, on every exit path (success,
-- failure, or asynchronous cancel), in strictly LIFO order.
data Scoped (m :: Type -> Type) :: Type -> Type where
  Region :: !ResourceKey -> m () -> m a -> Scoped m a

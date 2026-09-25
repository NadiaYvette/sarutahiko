{-# LANGUAGE GADTs #-}
-- |
-- Module      : Sarutahiko.Effect.Signatures
-- Description : Neutral algebraic effect signatures and canonical Stepper
module Sarutahiko.Effect.Signatures
  ( -- * Stepper
    Stepper (..)
  ) where

import Data.Kind (Type)

-- | Canonical sequential traversal handle unifying DB cursors,
-- SSE subscriptions, and event streams.
data Stepper (m :: Type -> Type) a where
  StepDone  :: Stepper m a
  StepYield :: !a -> m (Stepper m a) -> Stepper m a
  StepError :: !String -> Stepper m a

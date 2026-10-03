{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Sarutahiko.Effect.Stepper
-- Description : Canonical existential cursor/stepper GADT
--
-- Unifies stream and database cursor traversal without inverting dependencies
-- on yamaarashi or fixing concrete effect rows per EFFECT_CATALOG_DESIGN.md §3.4.
module Sarutahiko.Effect.Stepper
  ( Stepper (..)
  , mkStepper
  , stepStepper
  , closeStepper
  , drainStepper
  , unfoldStepper
  , mapStepper
  ) where

-- | The canonical existential stepper GADT.
--
-- Exposes sequential, pull-based traversal across database cursors, event streams,
-- and subscription handles. Unfolds into yamaarashi streams at the consumer edge.
data Stepper m a where
  Stepper :: st
          -> (st -> m (Maybe (a, st)))  -- ^ step: Nothing = exhaustion / terminal reached
          -> (st -> m ())               -- ^ close: deterministic teardown
          -> Stepper m a

-- | Construct a 'Stepper' from initial state, a step function, and a close action.
mkStepper :: st -> (st -> m (Maybe (a, st))) -> (st -> m ()) -> Stepper m a
mkStepper = Stepper

-- | Advance a stepper one step, returning the value and the updated stepper.
stepStepper :: Functor m => Stepper m a -> m (Maybe (a, Stepper m a))
stepStepper (Stepper st step close) =
  fmap (\(a, nextSt) -> (a, Stepper nextSt step close)) <$> step st

-- | Deterministically close a stepper.
closeStepper :: Stepper m a -> m ()
closeStepper (Stepper st _ close) = close st

-- | Drain all items from a stepper into a list, guaranteeing teardown upon exhaustion.
drainStepper :: Monad m => Stepper m a -> m [a]
drainStepper (Stepper st step close) = go st []
  where
    go s acc = do
      mNext <- step s
      case mNext of
        Nothing -> close s >> pure (reverse acc)
        Just (a, s') -> go s' (a : acc)

-- | Construct a pure list-backed stepper for testing and mock streams.
unfoldStepper :: Applicative m => [a] -> Stepper m a
unfoldStepper xs = Stepper xs step close
  where
    step []     = pure Nothing
    step (y:ys) = pure (Just (y, ys))
    close _     = pure ()

-- | Map a pure function over the elements produced by a stepper.
mapStepper :: Functor m => (a -> b) -> Stepper m a -> Stepper m b
mapStepper f (Stepper st step close) =
  Stepper st (fmap (fmap (\(a, s') -> (f a, s'))) . step) close

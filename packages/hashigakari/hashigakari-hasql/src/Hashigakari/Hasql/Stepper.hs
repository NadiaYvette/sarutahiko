{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Hashigakari.Hasql.Stepper
-- Description : Existential PostgreSQL row steppers
--
-- Adapts binary PostgreSQL cursor results into the canonical existential
-- 'Stepper IO (Record Identity r)' per HASHIGAKARI_DESIGN.md §3.4.
-- Guarantees bracketed cursor and connection closure on short-circuit.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql' (Nikita Volkov) — PostgreSQL cursors
-- * 'yamaarashi' — canonical existential Stepper streaming
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql.Stepper
  ( stepHasqlRows
  , stepHasqlStream
  ) where

import Control.Exception (onException)
import Control.Monad (unless)
import Data.Functor.Identity (Identity)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Record.Anon.Advanced (Record)

import Sarutahiko.Effect.Stepper (Stepper, mkStepper)

data HasqlStepperState r = HasqlStepperState
  { hssRows      :: ![Record Identity r]
  , hssFinalized :: !(IORef Bool)
  , hssTeardown  :: !(IO ())
  }

-- | Atomically run the teardown hook once.
closeHasqlStepper :: HasqlStepperState r -> IO ()
closeHasqlStepper st = do
  already <- atomicModifyIORef' (hssFinalized st) (\fin -> (True, fin))
  unless already $
    hssTeardown st

-- | Construct a 'Stepper IO (Record Identity r)' from a list of rows with a bracketed teardown.
stepHasqlRows
  :: [Record Identity r]
  -> IO ()
  -> IO (Stepper IO (Record Identity r))
stepHasqlRows rows teardown = do
  ref <- newIORef False
  let st0 = HasqlStepperState rows ref teardown
      stepAct st = do
        isFin <- readIORef (hssFinalized st)
        if isFin
          then pure Nothing
          else case hssRows st of
            [] -> do
              closeHasqlStepper st
              pure Nothing
            (r:rs) ->
              pure (Just (r, st { hssRows = rs }))
  pure (mkStepper st0 stepAct closeHasqlStepper)

-- | Construct a streaming stepper from a step action and teardown.
stepHasqlStream
  :: IO (Maybe (Record Identity r))
  -> IO ()
  -> IO (Stepper IO (Record Identity r))
stepHasqlStream pullNext teardown = do
  ref <- newIORef False
  let stepAct isFinRef = do
        isFin <- readIORef isFinRef
        if isFin
          then pure Nothing
          else do
            mNext <- pullNext `onException` teardown
            case mNext of
              Nothing -> do
                already <- atomicModifyIORef' isFinRef (\fin -> (True, fin))
                unless already teardown
                pure Nothing
              Just row ->
                pure (Just (row, isFinRef))
      closeAct isFinRef = do
        already <- atomicModifyIORef' isFinRef (\fin -> (True, fin))
        unless already teardown
  pure (mkStepper ref stepAct closeAct)

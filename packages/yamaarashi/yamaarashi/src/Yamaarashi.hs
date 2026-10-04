{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Yamaarashi
-- Description : Church-encoded CPS free-monad element streaming kernel
--
-- Pure, dependency-free element streaming kernel implementing O(1) left-associated
-- monadic binds via Codensity / Church encoding per YAMAARASHI_DESIGN.md.
--
-- Unrolls existential Steppers from 'Sarutahiko.Effect.Stepper' into streams at the
-- consumer edge, and supports typed concurrency execution strategies ('Serial',
-- 'Async', 'Interleaved', 'Parallel').
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts from:
-- * 'streaming' (Michael Thompson) — Church-encoded CPS free monad transformer ('Stream (Of a) m r')
-- * 'streamly' (Harendra Kumar / Composewell Technologies, Apache-2.0 / BSD-3) — sequential stream fusion and concurrency models
-- * 'conduit' (Michael Snoyman) — bracketed resource reclamation and push/pull stream composition
-- See @NOTICE.md@ and @LICENSES/NOTICE-streamly.txt@ at the repository root.
module Yamaarashi
  ( -- * Pair Producer Shape
    Of (..)
    -- * Stream Type
  , Stream (..)
  , FreeF (..)
  , FreeT (..)
  , toFreeT
  , fromFreeT
    -- * Core Combinators
  , yield
  , await
  , inspect
  , next
  , cons
  , uncons
  , fold
  , fold_
  , foldM
  , map
  , mapM
  , filter
  , take
  , drop
  , each
  , toList
  , toList_
  , zipWith
  , zipWith_
  , effect
  , lift
    -- * Stepper Integration
  , unfoldStepper
    -- * Concurrency & Scheduling Strategies
  , Strategy (..)
  , Strategic (..)
  , serial
  , async
  , interleaved
  , parallel
  ) where

import Control.Monad (ap, void)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Bifunctor (Bifunctor (..))
import Data.Kind (Type)
import Prelude hiding (drop, filter, map, mapM, take, zipWith)
import Sarutahiko.Effect.Stepper (Stepper (..))


-- | Strict pair constructor representing element production in a stream.
--
-- In @Stream (Of a) m r@, @Of a@ acts as the step functor @a :> rest@.
data Of a b = !a :> b
  deriving stock (Eq, Ord, Show, Read)

infixr 5 :>

instance Functor (Of a) where
  fmap f (a :> b) = a :> f b

instance Bifunctor Of where
  bimap f g (a :> b) = f a :> g b

instance Foldable (Of a) where
  foldMap f (_ :> b) = f b

instance Traversable (Of a) where
  traverse f (a :> b) = (a :>) <$> f b

-- | Church-encoded (CPS) free-monad stream kernel.
--
-- Polymorphic in the step functor @f@ and base monad @m@, with termination result @a@.
-- By maintaining continuations in CPS form, left-associated binds @(s >>= f) >>= g@
-- execute in O(1) time without rebalancing tree structures.
newtype Stream f m a = Stream
  { unStream :: forall r. (a -> m r) -> (forall x. (x -> m r) -> f x -> m r) -> m r }

instance Functor (Stream f m) where
  fmap f (Stream run) = Stream $ \done step ->
    run (done . f) step

instance Applicative (Stream f m) where
  pure a = Stream $ \done _ -> done a
  (<*>) = ap

instance Monad (Stream f m) where
  Stream run >>= k = Stream $ \done step ->
    run (\a -> unStream (k a) done step) step

instance MonadIO m => MonadIO (Stream f m) where
  liftIO action = lift (liftIO action)

instance Semigroup a => Semigroup (Stream f m a) where
  s1 <> s2 = do
    r1 <- s1
    r2 <- s2
    pure (r1 <> r2)

instance Monoid a => Monoid (Stream f m a) where
  mempty = pure mempty

-- | Explicit step functor for stepped evaluation.
data FreeF f a b = Return a | Step !(f b)

-- | Materialized FreeT wrapper for stepping and pattern matching.
newtype FreeT f m a = FreeT { runFreeT :: m (FreeF f a (FreeT f m a)) }

-- | Convert a church-encoded stream into its materialized 'FreeT' representation.
toFreeT :: (Functor f, Monad m) => Stream f m a -> FreeT f m a
toFreeT (Stream run) =
  FreeT $ run (pure . Return) (\h fx -> pure (Step (fmap (\x -> FreeT (h x)) fx)))

-- | Embed a materialized 'FreeT' representation into a church-encoded stream.
fromFreeT :: (Functor f, Monad m) => FreeT f m a -> Stream f m a
fromFreeT (FreeT m) = Stream $ \done step ->
  m >>= \case
    Return a -> done a
    Step fx  -> step (\rest -> unStream (fromFreeT rest) done step) fx

-- | Lift an action from the underlying monad @m@ into the stream.
lift :: Monad m => m r -> Stream f m r
lift action = Stream $ \done _ -> action >>= done

-- | Lift a monadic computation returning a stream.
effect :: Monad m => m (Stream f m r) -> Stream f m r
effect action = lift action >>= id

-- | Yield a single element into the stream.
yield :: a -> Stream (Of a) m ()
yield a = Stream $ \done step -> step done (a :> ())


-- | Inspect the next step of a stream.
--
-- Returns @Left r@ on stream completion, or @Right (a :> rest)@ when an element is produced.
inspect :: Monad m => Stream (Of a) m r -> m (Either r (Of a (Stream (Of a) m r)))
inspect s = do
  res <- runFreeT (toFreeT s)
  case res of
    Return r -> pure (Left r)
    Step (a :> rest) -> pure (Right (a :> fromFreeT rest))

-- | Step a stream, yielding either the termination value @Left r@ or the next element
-- paired with the remaining stream @Right (a, rest)@.
next :: Monad m => Stream (Of a) m r -> m (Either r (a, Stream (Of a) m r))
next s = do
  res <- inspect s
  case res of
    Left r -> pure (Left r)
    Right (a :> rest) -> pure (Right (a, rest))

-- | Prepend an element to a stream.
cons :: a -> Stream (Of a) m r -> Stream (Of a) m r
cons a rest = Stream $ \done step -> step (\() -> unStream rest done step) (a :> ())

-- | Synonym for 'next'.
uncons :: Monad m => Stream (Of a) m r -> m (Either r (a, Stream (Of a) m r))
uncons = next

-- | Pull a single element from a stream if available.
await :: Monad m => Stream (Of a) m r -> m (Maybe (a, Stream (Of a) m r))
await s = do
  res <- next s
  case res of
    Left _ -> pure Nothing
    Right (a, rest) -> pure (Just (a, rest))

-- | Fold a stream strictly with an accumulator and projection, preserving the result value.
fold :: Monad m => (s -> a -> s) -> s -> (s -> b) -> Stream (Of a) m r -> m (Of b r)
fold step !acc done s = do
  res <- next s
  case res of
    Left r -> pure (done acc :> r)
    Right (a, rest) -> fold step (step acc a) done rest

-- | Strict left fold over all elements, discarding the stream return value.
fold_ :: Monad m => (s -> a -> s) -> s -> Stream (Of a) m r -> m s
fold_ step !acc s = do
  (b :> _) <- fold step acc id s
  pure b

-- | Monadic strict left fold preserving the return value.
foldM :: Monad m => (s -> a -> m s) -> m s -> (s -> m b) -> Stream (Of a) m r -> m (Of b r)
foldM step initAcc done s = do
  acc0 <- initAcc
  go acc0 s
  where
    go !acc stream = do
      res <- next stream
      case res of
        Left r -> do
          b <- done acc
          pure (b :> r)
        Right (a, rest) -> do
          acc' <- step acc a
          go acc' rest

-- | Map a pure function over all elements of a stream.
map :: Monad m => (a -> b) -> Stream (Of a) m r -> Stream (Of b) m r
map f s = do
  res <- lift (next s)
  case res of
    Left r -> pure r
    Right (a, rest) -> do
      yield (f a)
      map f rest

-- | Map a monadic action over all elements of a stream.
mapM :: Monad m => (a -> m b) -> Stream (Of a) m r -> Stream (Of b) m r
mapM f s = do
  res <- lift (next s)
  case res of
    Left r -> pure r
    Right (a, rest) -> do
      b <- lift (f a)
      yield b
      mapM f rest

-- | Filter elements matching a predicate.
filter :: Monad m => (a -> Bool) -> Stream (Of a) m r -> Stream (Of a) m r
filter p s = do
  res <- lift (next s)
  case res of
    Left r -> pure r
    Right (a, rest)
      | p a       -> yield a >> filter p rest
      | otherwise -> filter p rest

-- | Take up to @n@ elements from a stream, then terminate.
take :: Monad m => Int -> Stream (Of a) m r -> Stream (Of a) m ()
take n s
  | n <= 0    = pure ()
  | otherwise = do
      res <- lift (next s)
      case res of
        Left _ -> pure ()
        Right (a, rest) -> do
          yield a
          take (n - 1) rest

-- | Drop the first @n@ elements from a stream.
drop :: Monad m => Int -> Stream (Of a) m r -> Stream (Of a) m r
drop n s
  | n <= 0    = s
  | otherwise = do
      res <- lift (next s)
      case res of
        Left r -> pure r
        Right (_, rest) -> drop (n - 1) rest

-- | Emit each element from any 'Foldable' container.
each :: Foldable t => t a -> Stream (Of a) m ()
each = foldr (\a rest -> yield a >> rest) (pure ())


-- | Drain a stream into a list, preserving the return value.
toList :: Monad m => Stream (Of a) m r -> m (Of [a] r)
toList s = fold (\acc a -> a : acc) [] reverse s

-- | Drain a stream into a list, discarding the return value.
toList_ :: Monad m => Stream (Of a) m r -> m [a]
toList_ s = reverse <$> fold_ (\acc a -> a : acc) [] s

-- | Zip two streams together with a combining function.
zipWith :: Monad m => (a -> b -> c) -> Stream (Of a) m r -> Stream (Of b) m r' -> Stream (Of c) m (Either r r')
zipWith f s1 s2 = do
  res1 <- lift (next s1)
  case res1 of
    Left r1 -> pure (Left r1)
    Right (a, rest1) -> do
      res2 <- lift (next s2)
      case res2 of
        Left r2 -> pure (Right r2)
        Right (b, rest2) -> do
          yield (f a b)
          zipWith f rest1 rest2

-- | Zip two streams together, discarding their return values.
zipWith_ :: Monad m => (a -> b -> c) -> Stream (Of a) m r -> Stream (Of b) m r' -> Stream (Of c) m ()
zipWith_ f s1 s2 = void (zipWith f s1 s2)

-- | Unroll an existential 'Stepper' from 'Sarutahiko.Effect.Stepper' into a 'Stream'.
--
-- Deterministically executes the stepper's finalizer upon stream exhaustion.
unfoldStepper :: Monad m => Stepper m a -> Stream (Of a) m ()
unfoldStepper (Stepper st step close) = go st
  where
    go s = do
      mNext <- lift (step s)
      case mNext of
        Nothing -> lift (close s)
        Just (a, s') -> do
          yield a
          go s'

-- | Concurrency and scheduling execution strategies for streaming pipelines.
--
-- Governs element-level concurrency, backpressure, and cancellation ownership
-- per YAMAARASHI_DESIGN.md §1 and NIH_PLAN.md §3.6.
data Strategy
  = Serial
  -- ^ Strictly sequential deterministic evaluation in the caller thread.
  | Async
  -- ^ Worker thread evaluation with a bounded buffer between producer and consumer.
  | Interleaved
  -- ^ Fair interleaving of elements across multiple streams.
  | Parallel
  -- ^ Simultaneous parallel evaluation of chunked branches with barrier synchronization.
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | Tagged stream wrapper enforcing an explicit scheduling strategy.
newtype Strategic (strat :: Strategy) (f :: Type -> Type) (m :: Type -> Type) a = Strategic
  { unStrategic :: Stream f m a }
  deriving newtype (Functor, Applicative, Monad)

-- | Tag a stream with the 'Serial' sequential strategy.
serial :: Stream f m a -> Strategic 'Serial f m a
serial = Strategic

-- | Tag a stream with the 'Async' buffered strategy.
async :: Stream f m a -> Strategic 'Async f m a
async = Strategic

-- | Tag a stream with the 'Interleaved' fair strategy.
interleaved :: Stream f m a -> Strategic 'Interleaved f m a
interleaved = Strategic

-- | Tag a stream with the 'Parallel' chunked strategy.
parallel :: Stream f m a -> Strategic 'Parallel f m a
parallel = Strategic

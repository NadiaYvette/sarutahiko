{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Streamly
-- Description : Fused in-process hot loops and element transforms
--
-- Embeds Streamly's fused stream representation for high-throughput in-process
-- element transformations and tabular row decoding per YAMAARASHI_DESIGN.md §3.
--
-- === Intellectual Lineage & Attribution
-- This module adapts and bridges Harendra Kumar's 'streamly' framework
-- (Composewell Technologies, Apache-2.0 / BSD-3-Clause).
-- See @LICENSES/NOTICE-streamly.txt@ and @NOTICE.md@ at the repository root.
module Yamaarashi.Streamly
  ( -- * Type Synonyms
    SerialT
    -- * Bidirectional Conversion
  , toStreamly
  , fromStreamly
    -- * High-Throughput Row Folding
  , foldRows
  , foldRowsM
  ) where

import qualified Streamly.Data.Fold as Fold
import Streamly.Data.Stream (Stream)
import qualified Streamly.Data.Stream as Stream
import Yamaarashi (Of (..))
import qualified Yamaarashi as Y

-- | Serial stream synonym corresponding to 'Streamly.Data.Stream.Stream'.
type SerialT m a = Stream m a

-- | Convert a neutral church-encoded 'Y.Stream' into a fused Streamly 'Stream'.
toStreamly :: Monad m => Y.Stream (Of a) m () -> Stream m a
toStreamly s = Stream.unfoldrM step s
  where
    step str = do
      res <- Y.next str
      case res of
        Left () -> pure Nothing
        Right (a, rest) -> pure (Just (a, rest))

-- | Convert a fused Streamly 'Stream' into a neutral church-encoded 'Y.Stream'.
fromStreamly :: Monad m => Stream m a -> Y.Stream (Of a) m ()
fromStreamly s = do
  mNext <- Y.lift (Stream.uncons s)
  case mNext of
    Nothing -> pure ()
    Just (a, rest) -> do
      Y.yield a
      fromStreamly rest

-- | Strict left fold over a stream of rows with fusion rewrite rules.
foldRows :: Monad m => (b -> a -> b) -> b -> Stream m a -> m b
foldRows f z s = Stream.fold (Fold.foldl' f z) s

-- | Monadic strict left fold over a stream of rows with fusion rewrite rules.
foldRowsM :: Monad m => (b -> a -> m b) -> m b -> Stream m a -> m b
foldRowsM f z s = Stream.fold (Fold.foldlM' f z) s

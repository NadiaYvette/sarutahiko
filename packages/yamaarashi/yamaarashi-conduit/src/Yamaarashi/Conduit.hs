{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Conduit
-- Description : Conduit boundary framing and process pipe adapters
--
-- Provides bidirectional bridging between the neutral 'Stream' kernel and Conduit,
-- high-performance line framing for stdio JSON-RPC, and deterministic cleanup
-- via 'MonadResource' per YAMAARASHI_DESIGN.md §3.
module Yamaarashi.Conduit
  ( -- * Bidirectional Conversion
    streamToConduit
  , conduitToStream
    -- * Line & JSON-RPC Framing
  , linesConduit
  , jsonRpcFraming
    -- * Deterministic Resource Bracketing
  , bracketResource
  , bracketStream
  ) where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Resource (MonadResource)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Conduit (ConduitT, (.|), await, sealConduitT, ($$++), ($$+-))
import qualified Data.Conduit as C
import qualified Data.Conduit.Combinators as CC
import Data.Conduit.Internal (ConduitT (..), bracketP)
import Yamaarashi (Of (..), Stream)
import qualified Yamaarashi as Y

-- | Convert a neutral church-encoded 'Stream' into a Conduit producer.
streamToConduit :: Monad m => Stream (Of a) m r -> ConduitT i a m r
streamToConduit stream = do
  res <- lift (Y.next stream)
  case res of
    Left r -> pure r
    Right (a, rest) -> do
      C.yield a
      streamToConduit rest

-- | Convert a Conduit source into a neutral church-encoded 'Stream'.
--
-- Deterministically finalizes the conduit source upon stream completion or exhaustion.
conduitToStream :: Monad m => ConduitT () a m () -> Stream (Of a) m ()
conduitToStream src = go (sealConduitT src)
  where
    go sealed = do
      (sealed', mVal) <- Y.lift (sealed $$++ await)
      case mVal of
        Nothing -> Y.lift (sealed' $$+- pure ())
        Just a -> do
          Y.yield a
          go sealed'

-- | Stream line splitter buffering ByteString chunks across line boundaries.
linesConduit :: Monad m => ConduitT ByteString ByteString m ()
linesConduit = CC.linesUnboundedAscii

-- | Strip trailing carriage return ('\r') if present.
stripCR :: ByteString -> ByteString
stripCR bs
  | BS.null bs = bs
  | BS.last bs == 13 = BS.init bs
  | otherwise = bs

-- | Stdio JSON-RPC line framing adapter.
--
-- Splits arbitrary ByteString chunk streams on newline boundaries, trims CRLF,
-- and filters out empty lines.
jsonRpcFraming :: Monad m => ConduitT ByteString ByteString m ()
jsonRpcFraming = linesConduit .| CC.filter (\bs -> not (BS.null (stripCR bs)))

-- | Run a conduit with bracketed acquisition and release registered in the resource monad.
bracketResource :: MonadResource m => IO a -> (a -> IO ()) -> (a -> ConduitT i o m r) -> ConduitT i o m r
bracketResource alloc cleanup inside =
  ConduitT $ \rest -> bracketP alloc cleanup (\a -> unConduitT (inside a) rest)

-- | Bracketed resource acquisition inside a 'Stream' guaranteed to run teardown upon completion.
bracketStream :: Monad m => m a -> (a -> m ()) -> (a -> Stream (Of o) m r) -> Stream (Of o) m r
bracketStream alloc release action = do
  res <- Y.lift alloc
  go res (action res)
  where
    go res stream = do
      stepRes <- Y.lift (Y.next stream)
      case stepRes of
        Left r -> do
          Y.lift (release res)
          pure r
        Right (o, rest) -> do
          Y.yield o
          go res rest

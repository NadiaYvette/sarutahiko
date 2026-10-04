{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Hashigakari.Hasql.Pool
-- Description : Connection pool bracket and resource lifecycle
--
-- Thread-safe connection pool with bracketed cleanup and bounded
-- worker leases per HASHIGAKARI_DESIGN.md §3.4.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql-pool' (Nikita Volkov) — bounded connection pooling
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql.Pool
  ( withHasqlPool
  , createPool
  , closePool
  , acquireConnection
  , releaseConnection
  , poolActiveCount
  ) where

import Control.Concurrent.STM
  ( atomically
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (bracket)

import Hashigakari.Hasql.Types
  ( HasqlConfig (..)
  , HasqlError (..)
  , HasqlPool (..)
  )

-- | Initialize a new connection pool.
createPool :: HasqlConfig -> IO HasqlPool
createPool cfg = do
  activeVar <- newTVarIO 0
  closedVar <- newTVarIO False
  pure $ HasqlPool
    { poolConfig = cfg
    , poolActive = activeVar
    , poolClosed = closedVar
    }

-- | Close all connections in the pool.
closePool :: HasqlPool -> IO ()
closePool pool = atomically $ writeTVar (poolClosed pool) True

-- | Bracketed connection pool execution guaranteeing pool disposal.
withHasqlPool :: HasqlConfig -> (HasqlPool -> IO a) -> IO a
withHasqlPool cfg = bracket (createPool cfg) closePool

-- | Acquire a connection lease from the pool.
acquireConnection :: HasqlPool -> IO (Either HasqlError ())
acquireConnection pool = atomically $ do
  isClosed <- readTVar (poolClosed pool)
  if isClosed
    then pure (Left (ConnectionError "Connection pool is closed"))
    else do
      curr <- readTVar (poolActive pool)
      if curr >= hcPoolSize (poolConfig pool)
        then pure (Left (PoolExhausted "Connection pool exhausted"))
        else do
          writeTVar (poolActive pool) (curr + 1)
          pure (Right ())

-- | Release a previously acquired connection lease back to the pool.
releaseConnection :: HasqlPool -> IO ()
releaseConnection pool = atomically $ do
  curr <- readTVar (poolActive pool)
  if curr > 0
    then writeTVar (poolActive pool) (curr - 1)
    else pure ()

-- | Query the current number of active checked-out connections.
poolActiveCount :: HasqlPool -> IO Int
poolActiveCount pool = readTVarIO (poolActive pool)

{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Hashigakari.Hasql.Types
-- Description : Configuration, pool handles, and error models for Hasql
--
-- Domain types for PostgreSQL connection management and query execution
-- per HASHIGAKARI_DESIGN.md §3.4.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql' & 'hasql-pool' (Nikita Volkov) — connection pool and session errors
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql.Types
  ( -- * Configuration
    HasqlConfig (..)
  , defaultHasqlConfig
    -- * Connection Pool Handle
  , HasqlPool (..)
    -- * Error Hierarchy
  , HasqlError (..)
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Data.Text (Text)

-- | PostgreSQL connection parameters.
data HasqlConfig = HasqlConfig
  { hcHost     :: !Text
  , hcPort     :: !Int
  , hcUser     :: !Text
  , hcPassword :: !Text
  , hcDatabase :: !Text
  , hcPoolSize :: !Int
  } deriving stock (Eq, Show)

-- | Default local developer PostgreSQL configuration.
defaultHasqlConfig :: HasqlConfig
defaultHasqlConfig = HasqlConfig
  { hcHost     = "127.0.0.1"
  , hcPort     = 5432
  , hcUser     = "postgres"
  , hcPassword = ""
  , hcDatabase = "postgres"
  , hcPoolSize = 10
  }

-- | Connection pool state handle.
data HasqlPool = HasqlPool
  { poolConfig :: !HasqlConfig
  , poolActive :: !(TVar Int)
  , poolClosed :: !(TVar Bool)
  }

-- | Structured error model for PostgreSQL execution.
data HasqlError
  = ConnectionError !Text
  | QueryError !Text
  | DecodingError !Text
  | PoolExhausted !Text
  deriving stock (Eq, Show)

instance Exception HasqlError

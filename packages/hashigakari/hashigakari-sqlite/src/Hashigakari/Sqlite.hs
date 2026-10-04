{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Hashigakari.Sqlite
-- Description : Embedded SQLite carrier for event store, task queue, and steppers
--
-- Top-level entry point for 'hashigakari-sqlite' per HASHIGAKARI_DESIGN.md and
-- DECISION-003. Provides hermetic SQLite persistence for the Phase 1.5 Hokora
-- vertical slice with zero external daemons.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes database principles from:
-- * 'direct-sqlite' (Irene Knittel, Jan Snajder) & SQLite — low-level C FFI statement stepping
-- * 'hasql' (Nikita Volkov) — applicative row decoding directly into strongly-typed structures
-- * 'beam' (Travis Whitaker) — relational schema and query composition (see LICENSES/NOTICE-beam.txt)
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Sqlite
  ( -- * Database Lifecycle
    openSqliteDatabase
  , withSqliteDatabase
  , openExistingSqliteDatabase
  , withExistingSqliteDatabase

    -- * Re-exports
  , module Hashigakari.Sqlite.Stepper
  , module Hashigakari.Sqlite.EventStore
  , module Hashigakari.Sqlite.TaskQueue
  , module Hashigakari.Sqlite.Capability
  ) where

import Control.Exception (bracket)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQLite
import Database.SQLite3 (Database)

import Hashigakari.Sqlite.Capability
import Hashigakari.Sqlite.EventStore
import Hashigakari.Sqlite.Stepper
import Hashigakari.Sqlite.TaskQueue

-- | Open and initialize an embedded SQLite database with 10000ms busy timeout, WAL mode,
-- and schema migration for 'events' and 'task_queue'.
openSqliteDatabase :: FilePath -> IO Database
openSqliteDatabase path = do
  db <- SQLite.open (T.pack path)
  SQLite.exec db "PRAGMA busy_timeout = 10000;"
  SQLite.exec db "PRAGMA journal_mode = WAL;"
  SQLite.exec db "PRAGMA synchronous = NORMAL;"
  initEventStoreTable db
  initTaskQueueTable db
  pure db

-- | Open an existing embedded SQLite database with 10000ms busy timeout without re-running DDL.
openExistingSqliteDatabase :: FilePath -> IO Database
openExistingSqliteDatabase path = do
  db <- SQLite.open (T.pack path)
  SQLite.exec db "PRAGMA busy_timeout = 10000;"
  SQLite.exec db "PRAGMA journal_mode = WAL;"
  SQLite.exec db "PRAGMA synchronous = NORMAL;"
  pure db

-- | Resource-bracketed database runner ensuring clean connection closure.
withSqliteDatabase :: FilePath -> (Database -> IO a) -> IO a
withSqliteDatabase path = bracket (openSqliteDatabase path) SQLite.close

-- | Resource-bracketed database runner for existing databases (skips DDL).
withExistingSqliteDatabase :: FilePath -> (Database -> IO a) -> IO a
withExistingSqliteDatabase path = bracket (openExistingSqliteDatabase path) SQLite.close

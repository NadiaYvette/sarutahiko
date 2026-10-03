{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

-- |
-- Module      : Hashigakari.Sqlite.EventStore
-- Description : SQLite EventStore carrier and conversation stream replay
--
-- Production interpreter for 'EventStore' appending and streaming 'large-anon'
-- event rows to an append-only event log table ('events') per HASHIGAKARI_DESIGN.md
-- and DECISION-003.
module Hashigakari.Sqlite.EventStore
  ( -- * Schema & Canonical Row
    EventRow
  , eventRowToStored
  , initEventStoreTable

    -- * Direct SQLite Operations
  , appendEventSqlite
  , readEventsSqlite
  , readEventsTail
  , foldEventsTail
  , streamEventsSqlite
  , replayEventsStream

    -- * Effect Interpreter
  , runEventStoreSqlite
  ) where

import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity, runIdentity)
import Data.Int (Int64)
import qualified Data.List as List
import Data.Record.Anon (pattern (:=))
import qualified Data.Record.Anon.Advanced as Anon
import Data.Record.Anon.Advanced (Record)
import Data.Text (Text)

import qualified Database.SQLite3 as SQLite
import Database.SQLite3 (Database, SQLData (..))

import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Effect.EventStore (EventId (..), EventStore (..), SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.Interpreter.Effectful ()
import Sarutahiko.Effect.Stepper (Stepper, drainStepper, mapStepper)
import Hashigakari.Sqlite.Stepper (stepRow)
import Yamaarashi (Of, Stream, unfoldStepper)

-- | Canonical 'large-anon' row descriptor matching the SQLite 'events' table schema.
type EventRow =
  '[ "id"         := Int64
   , "session_id" := Text
   , "event_type" := Text
   , "payload"    := ByteString
   , "created_at" := Text
   ]

-- | Project an anonymous 'EventRow' record into a domain 'StoredEvent'.
eventRowToStored :: Record Identity EventRow -> StoredEvent
eventRowToStored r = StoredEvent
  { eventId        = runIdentity (Anon.get #id r)
  , eventSessionId = runIdentity (Anon.get #session_id r)
  , eventType      = runIdentity (Anon.get #event_type r)
  , eventPayload   = runIdentity (Anon.get #payload r)
  , eventCreatedAt = runIdentity (Anon.get #created_at r)
  }

-- | Create the append-only 'events' table and session indexing.
initEventStoreTable :: Database -> IO ()
initEventStoreTable db = do
  SQLite.exec db
    "CREATE TABLE IF NOT EXISTS events (\
    \  id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \  session_id TEXT NOT NULL,\
    \  event_type TEXT NOT NULL,\
    \  payload BLOB NOT NULL,\
    \  created_at DATETIME DEFAULT CURRENT_TIMESTAMP\
    \);\
    \CREATE INDEX IF NOT EXISTS idx_events_session_id ON events (session_id, id);"

-- | Append an event row to the SQLite event store and return the generated 'EventId'.
appendEventSqlite :: Database -> SessionId -> Text -> ByteString -> IO EventId
appendEventSqlite db (SessionId sid) evType payload = do
  let sql = "INSERT INTO events (session_id, event_type, payload) VALUES (?, ?, ?);"
  SQLite.withStatement db sql $ \stmt -> do
    SQLite.bind stmt [SQLText sid, SQLText evType, SQLBlob payload]
    _ <- SQLite.step stmt
    rowId <- SQLite.lastInsertRowId db
    pure (EventId rowId)

-- | Read all events for a given session in monotonically increasing sequence.
readEventsSqlite :: Database -> SessionId -> IO [StoredEvent]
readEventsSqlite db sid = do
  stepper <- streamEventsSqlite db sid
  drainStepper stepper

-- | Read the conversation tail: the last @n@ events for a given session.
readEventsTail :: Database -> SessionId -> Int -> IO [StoredEvent]
readEventsTail db (SessionId sid) n = do
  let sql = "SELECT id, session_id, event_type, payload, created_at FROM (\
            \  SELECT id, session_id, event_type, payload, created_at FROM events \
            \  WHERE session_id = ? ORDER BY id DESC LIMIT ?\
            \) ORDER BY id ASC;"
  stmt <- SQLite.prepare db sql
  SQLite.bind stmt [SQLText sid, SQLInteger (fromIntegral n)]
  let stepper = stepRow @EventRow stmt
  drainStepper (mapStepper eventRowToStored stepper)

-- | Pure left fold over conversation tail events without buffering full history.
foldEventsTail
  :: Database
  -> SessionId
  -> Int
  -> (b -> StoredEvent -> b)
  -> b
  -> IO b
foldEventsTail db sid n f z = do
  evs <- readEventsTail db sid n
  pure (List.foldl' f z evs)

-- | Unfold an existential stepper streaming 'StoredEvent' records directly from SQLite.
streamEventsSqlite :: Database -> SessionId -> IO (Stepper IO StoredEvent)
streamEventsSqlite db (SessionId sid) = do
  let sql = "SELECT id, session_id, event_type, payload, created_at FROM events \
            \WHERE session_id = ? ORDER BY id ASC;"
  stmt <- SQLite.prepare db sql
  SQLite.bind stmt [SQLText sid]
  let rowStepper = stepRow @EventRow stmt
  pure (mapStepper eventRowToStored rowStepper)

-- | Unfold the session event stream into a canonical 'yamaarashi' stream.
replayEventsStream :: Database -> SessionId -> Stream (Of StoredEvent) IO ()
replayEventsStream db sid = do
  stepper <- liftIO (streamEventsSqlite db sid)
  unfoldStepper stepper

-- | Production interpreter for the neutral 'EventStore' effect using SQLite.
runEventStoreSqlite
  :: (IOE :> es)
  => Database
  -> Eff (EventStore : es) a
  -> Eff es a
runEventStoreSqlite db = interpret $ \_ -> \case
  AppendEvent sid evType payload -> liftIO $ appendEventSqlite db sid evType payload
  ReadEvents sid                 -> liftIO $ readEventsSqlite db sid

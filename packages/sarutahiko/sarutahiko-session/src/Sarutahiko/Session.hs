{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Session
-- Description : High-level session persistence and hydration API (utaibon / 謡本)
--
-- Connects 'hashigakari-sqlite' event storage to the conversation-tail reducer
-- providing prompt-cache-safe session persistence per MEMORY_ENGINE_DESIGN.md.
module Sarutahiko.Session
  ( -- * High-Level Session API
    openSession
  , appendSessionEvent
  , readSessionEvents
  , readSessionContext
  , closeSession
  , withSession

    -- * Re-exports
  , module Sarutahiko.Session.Types
  , module Sarutahiko.Session.Reducer
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Hashigakari.Sqlite
  ( appendEventSqlite
  , openSqliteDatabase
  , readEventsSqlite
  , withSqliteDatabase
  )
import Sarutahiko.Effect.EventStore (EventId, SessionId (..), StoredEvent (..))
import Sarutahiko.Session.Reducer
import Sarutahiko.Session.Types

-- | Open a session in SQLite, logging 'session_opened' event if not yet logged.
openSession :: FilePath -> SessionId -> Text -> FilePath -> IO SessionHandle
openSession dbPath sid model cwd = do
  db <- openSqliteDatabase dbPath
  existing <- readEventsSqlite db sid
  if null existing
    then do
      _ <- appendEventSqlite db sid "session_opened" (encodeSessionOpened model cwd)
      pure (SessionHandle db sid)
    else pure (SessionHandle db sid)

-- | Append an arbitrary event to the session event log.
appendSessionEvent :: SessionHandle -> Text -> ByteString -> IO EventId
appendSessionEvent (SessionHandle db sid) evType payload =
  appendEventSqlite db sid evType payload

-- | Read all raw events for this session.
readSessionEvents :: SessionHandle -> IO [StoredEvent]
readSessionEvents (SessionHandle db sid) =
  readEventsSqlite db sid

-- | Hydrate the active 'SessionContext' from SQLite by folding the reducer.
readSessionContext :: SessionHandle -> IO SessionContext
readSessionContext h@(SessionHandle _ sid) = do
  evs <- readSessionEvents h
  pure (reduceSessionEvents sid evs)

-- | Mark session as closed in the event log.
closeSession :: SessionHandle -> Text -> IO ()
closeSession h reason = do
  _ <- appendSessionEvent h "session_closed" (encodeSessionClosed reason)
  pure ()

-- | Resource-bracketed session lifecycle runner.
withSession :: FilePath -> SessionId -> Text -> FilePath -> (SessionHandle -> IO a) -> IO a
withSession dbPath sid model cwd action =
  withSqliteDatabase dbPath $ \db -> do
    existing <- readEventsSqlite db sid
    if null existing
      then do
        _ <- appendEventSqlite db sid "session_opened" (encodeSessionOpened model cwd)
        action (SessionHandle db sid)
      else action (SessionHandle db sid)

{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Yamaarashi.Flow.Ledger
-- Description : Typed SQLite event store and pure Kanban projection
--
-- Manages task lifecycle event persistence without external sqlite3 CLI
-- subprocess calls, and computes pure Kanban board state projections
-- per AGENTIC_TASK_MANAGEMENT_DESIGN.md and TP-ATM-0.6.
--
-- === Intellectual Lineage & Attribution
-- * Hashigakari / Keiki (Nadeem Bitar) — event-sourcing transducers
-- * Build Systems à la Carte (Andrey Mokhov) — scheduler state projections
-- See @NOTICE.md@ at the repository root.
module Yamaarashi.Flow.Ledger
  ( -- * Database Lifecycle
    initTaskLedger
  , logTaskEvent
  , readTaskEvents
  , withTaskDatabase

    -- * Pure Kanban Projection
  , KanbanColumn (..)
  , KanbanCard (..)
  , KanbanBoard (..)
  , projectKanban
  ) where

import Control.Exception (bracket)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQLite

-- | Columns of the agentic Kanban board.
data KanbanColumn
  = ColBacklog
  | ColReady
  | ColInProgress
  | ColVerifying
  | ColDone
  | ColFailed
  deriving stock (Eq, Ord, Show)

-- | State of a single task packet on the board.
data KanbanCard = KanbanCard
  { kcTaskId    :: !Text
  , kcColumn    :: !KanbanColumn
  , kcAttempts  :: !Int
  , kcLastEvent :: !Text
  } deriving stock (Eq, Show)

-- | The projected Kanban board state.
newtype KanbanBoard = KanbanBoard
  { kbCards :: Map.Map Text KanbanCard
  } deriving stock (Eq, Show)

-- | Execute an action with an opened SQLite database connection.
withTaskDatabase :: FilePath -> (SQLite.Database -> IO a) -> IO a
withTaskDatabase dbPath = bracket (SQLite.open (T.pack dbPath)) SQLite.close
  where
    _ = dbPath

-- | Initialize the task_events schema in SQLite.
initTaskLedger :: FilePath -> IO ()
initTaskLedger dbPath = withTaskDatabase dbPath $ \db -> do
  SQLite.exec db
    "CREATE TABLE IF NOT EXISTS task_events (\
    \  id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \  task_id TEXT NOT NULL,\
    \  event_type TEXT NOT NULL,\
    \  payload TEXT NOT NULL,\
    \  created_at DATETIME DEFAULT CURRENT_TIMESTAMP\
    \);"

-- | Append a task event into the SQLite store.
logTaskEvent :: FilePath -> Text -> Text -> Text -> IO ()
logTaskEvent dbPath tId evType payload = withTaskDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db "INSERT INTO task_events (task_id, event_type, payload) VALUES (?, ?, ?);"
  SQLite.bind stmt
    [ SQLite.SQLText tId
    , SQLite.SQLText evType
    , SQLite.SQLText payload
    ]
  _ <- SQLite.step stmt
  SQLite.finalize stmt

-- | Read all events for a given task from SQLite in order.
readTaskEvents :: FilePath -> Text -> IO [(Int64, Text, Text, Text)]
readTaskEvents dbPath tId = withTaskDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db "SELECT id, task_id, event_type, payload FROM task_events WHERE task_id = ? ORDER BY id ASC;"
  SQLite.bind stmt [SQLite.SQLText tId]
  rows <- collectRows stmt []
  SQLite.finalize stmt
  pure rows
  where
    collectRows stmt acc = do
      res <- SQLite.step stmt
      case res of
        SQLite.Row -> do
          rowId <- SQLite.column stmt 0 >>= \case
            SQLite.SQLInteger n -> pure n
            _                   -> pure 0
          taskId <- SQLite.column stmt 1 >>= \case
            SQLite.SQLText t -> pure t
            _                -> pure ""
          evType <- SQLite.column stmt 2 >>= \case
            SQLite.SQLText t -> pure t
            _                -> pure ""
          payload <- SQLite.column stmt 3 >>= \case
            SQLite.SQLText t -> pure t
            _                -> pure ""
          collectRows stmt ((rowId, taskId, evType, payload) : acc)
        SQLite.Done -> pure (reverse acc)

-- | Project an event stream into a Kanban board state.
projectKanban :: [(Text, Text, Text)] -> KanbanBoard
projectKanban events = KanbanBoard (foldl stepEvent Map.empty events)
  where
    stepEvent acc (tId, evType, _payload) =
      let prevCard = Map.findWithDefault (KanbanCard tId ColBacklog 0 "") tId acc
          newCard = applyEvent evType prevCard
      in Map.insert tId newCard acc

    applyEvent evType card = case evType of
      "TASK_ENQUEUED"        -> card { kcColumn = ColReady, kcLastEvent = evType }
      "TASK_STARTED"         -> card { kcColumn = ColReady, kcLastEvent = evType }
      "WORKTREE_PROVISIONED" -> card { kcColumn = ColReady, kcLastEvent = evType }
      "STEP_STARTED"         -> card { kcColumn = ColInProgress, kcAttempts = kcAttempts card + 1, kcLastEvent = evType }
      "STEP_EXECUTED"        -> card { kcColumn = ColInProgress, kcLastEvent = evType }
      "VERIFICATION_STARTED" -> card { kcColumn = ColVerifying, kcLastEvent = evType }
      "VERIFICATION_PASSED"  -> card { kcColumn = ColDone, kcLastEvent = evType }
      "COMMIT_CREATED"       -> card { kcColumn = ColDone, kcLastEvent = evType }
      "TASK_COMPLETED"       -> card { kcColumn = ColDone, kcLastEvent = evType }
      "STEP_FAILED"          -> card { kcColumn = ColFailed, kcLastEvent = evType }
      "VERIFICATION_FAILED"  -> card { kcColumn = ColFailed, kcLastEvent = evType }
      _                      -> card { kcLastEvent = evType }

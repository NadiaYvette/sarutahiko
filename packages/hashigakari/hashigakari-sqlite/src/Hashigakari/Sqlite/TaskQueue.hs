{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Hashigakari.Sqlite.TaskQueue
-- Description : SQLite TaskQueue carrier with atomic transaction leases
--
-- Production interpreter for 'TaskQueue' managing task dispatch, status
-- transitions (Pending, Claimed, Completed, Failed), and atomic transaction leases
-- per HASHIGAKARI_DESIGN.md and DECISION-003.
module Hashigakari.Sqlite.TaskQueue
  ( -- * Schema Initialization
    initTaskQueueTable

    -- * Direct SQLite Operations
  , enqueueTaskSqlite
  , claimTaskSqlite
  , completeTaskSqlite
  , failTaskSqlite
  , getTaskStatusSqlite

    -- * Effect Interpreters
  , runTaskQueueSqlite
  , runTaskQueueSqliteWithLease
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import qualified Database.SQLite3 as SQLite
import Database.SQLite3 (ColumnIndex (..), Database, SQLData (..), StepResult (..))

import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Effect.Interpreter.Effectful ()
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskQueue (..), TaskResult (..), WorkerId (..))

-- | Retrieve current POSIX seconds as an integer.
nowSecs :: IO Int64
nowSecs = round . utcTimeToPOSIXSeconds <$> getCurrentTime

-- | Create the 'task_queue' table and lease indexing.
initTaskQueueTable :: Database -> IO ()
initTaskQueueTable db = do
  SQLite.exec db
    "CREATE TABLE IF NOT EXISTS task_queue (\
    \  task_id TEXT PRIMARY KEY,\
    \  payload BLOB NOT NULL,\
    \  status TEXT NOT NULL,\
    \  worker_id TEXT,\
    \  lease_until INTEGER,\
    \  result BLOB,\
    \  created_at INTEGER NOT NULL,\
    \  updated_at INTEGER NOT NULL\
    \);\
    \CREATE INDEX IF NOT EXISTS idx_task_queue_status_lease\
    \  ON task_queue (status, lease_until, created_at);"

-- | Enqueue a new task or reset an existing task to 'Pending'.
enqueueTaskSqlite :: Database -> TaskId -> TaskPacket -> IO ()
enqueueTaskSqlite db (TaskId tid) (TaskPacket payload) = do
  now <- nowSecs
  let sql = "INSERT INTO task_queue (task_id, payload, status, worker_id, lease_until, result, created_at, updated_at) \
            \VALUES (?, ?, 'Pending', NULL, NULL, NULL, ?, ?) \
            \ON CONFLICT(task_id) DO UPDATE SET \
            \  payload = excluded.payload, \
            \  status = 'Pending', \
            \  worker_id = NULL, \
            \  lease_until = NULL, \
            \  result = NULL, \
            \  updated_at = excluded.updated_at;"
  SQLite.withStatement db sql $ \stmt -> do
    SQLite.bind stmt [SQLText tid, SQLBlob payload, SQLInteger now, SQLInteger now]
    _ <- SQLite.step stmt
    pure ()

-- | Atomically claim the oldest pending or expired task with a time-limited lease.
-- Uses 'BEGIN IMMEDIATE' to prevent concurrent workers from claiming the same task,
-- with automatic retry on transient SQLite3 ErrorBusy conditions.
claimTaskSqlite :: Database -> NominalDiffTime -> WorkerId -> IO (Maybe TaskPacket)
claimTaskSqlite db leaseDuration (WorkerId wid) = go (20 :: Int)
  where
    go retries = do
      mBegin <- try @SQLite.SQLError (SQLite.exec db "BEGIN IMMEDIATE;")
      case mBegin of
        Left err
          | SQLite.sqlError err == SQLite.ErrorBusy && retries > 0 -> do
              threadDelay 10000 -- 10ms backoff
              go (retries - 1)
          | otherwise -> throwIO err
        Right () -> do
          res <- try @SomeException $ do
            now <- nowSecs
            let leaseSecs = round (nominalDiffTimeToSeconds leaseDuration) :: Int64
                newLease = now + leaseSecs
                selectSql = "SELECT task_id, payload FROM task_queue \
                            \WHERE status = 'Pending' OR (status = 'Claimed' AND lease_until <= ?) \
                            \ORDER BY created_at ASC LIMIT 1;"
            mCandidate <- SQLite.withStatement db selectSql $ \stmt -> do
              SQLite.bind stmt [SQLInteger now]
              stepRes <- SQLite.step stmt
              case stepRes of
                Row -> do
                  tid <- SQLite.columnText stmt (ColumnIndex 0)
                  payload <- SQLite.columnBlob stmt (ColumnIndex 1)
                  pure (Just (tid, payload))
                Done -> pure Nothing

            case mCandidate of
              Nothing -> do
                SQLite.exec db "COMMIT;"
                pure Nothing
              Just (claimedTid, payload) -> do
                let updateSql = "UPDATE task_queue \
                                \SET status = 'Claimed', worker_id = ?, lease_until = ?, updated_at = ? \
                                \WHERE task_id = ?;"
                SQLite.withStatement db updateSql $ \updateStmt -> do
                  SQLite.bind updateStmt [SQLText wid, SQLInteger newLease, SQLInteger now, SQLText claimedTid]
                  _ <- SQLite.step updateStmt
                  pure ()
                SQLite.exec db "COMMIT;"
                pure (Just (TaskPacket payload))

          case res of
            Left ex -> do
              _ <- try @SomeException (SQLite.exec db "ROLLBACK;")
              throwIO ex
            Right ok -> pure ok

-- | Mark a task as completed with its final result.
completeTaskSqlite :: Database -> TaskId -> TaskResult -> IO ()
completeTaskSqlite db (TaskId tid) res = do
  now <- nowSecs
  let (resBlob, statusText) = case res of
        TaskSuccess bs  -> (SQLBlob bs, "Completed")
        TaskFailure err -> (SQLBlob (TE.encodeUtf8 err), "Failed")
      sql = "UPDATE task_queue \
            \SET status = ?, result = ?, updated_at = ? \
            \WHERE task_id = ?;"
  SQLite.withStatement db sql $ \stmt -> do
    SQLite.bind stmt [SQLText statusText, resBlob, SQLInteger now, SQLText tid]
    _ <- SQLite.step stmt
    pure ()

-- | Mark a task as failed with an error message.
failTaskSqlite :: Database -> TaskId -> Text -> IO ()
failTaskSqlite db tid err = completeTaskSqlite db tid (TaskFailure err)

-- | Query the current status of a task by ID.
getTaskStatusSqlite :: Database -> TaskId -> IO (Maybe Text)
getTaskStatusSqlite db (TaskId tid) = do
  let sql = "SELECT status FROM task_queue WHERE task_id = ?;"
  SQLite.withStatement db sql $ \stmt -> do
    SQLite.bind stmt [SQLText tid]
    stepRes <- SQLite.step stmt
    case stepRes of
      Row  -> Just <$> SQLite.columnText stmt (ColumnIndex 0)
      Done -> pure Nothing

-- | Run the 'TaskQueue' effect with configurable lease duration.
runTaskQueueSqliteWithLease
  :: (IOE :> es)
  => NominalDiffTime
  -> Database
  -> Eff (TaskQueue : es) a
  -> Eff es a
runTaskQueueSqliteWithLease leaseDuration db = interpret $ \_ -> \case
  EnqueueTask tid pkt    -> liftIO $ enqueueTaskSqlite db tid pkt
  ClaimTask wid          -> liftIO $ claimTaskSqlite db leaseDuration wid
  CompleteTask tid res   -> liftIO $ completeTaskSqlite db tid res
  FailTask tid err       -> liftIO $ failTaskSqlite db tid err

-- | Run the 'TaskQueue' effect using direct-sqlite with a default 300s lease.
runTaskQueueSqlite
  :: (IOE :> es)
  => Database
  -> Eff (TaskQueue : es) a
  -> Eff es a
runTaskQueueSqlite = runTaskQueueSqliteWithLease 300

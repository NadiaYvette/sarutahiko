{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Effect.Testkit.STM
-- Description : Pure in-memory STM carrier for EventStore and TaskQueue
--
-- Provides zero-IO STM carriers for dual-interpreter parity testing
-- and instant simulation per DECISION-003.
module Sarutahiko.Effect.Testkit.STM
  ( -- * STM EventStore Carrier
    StmEventStoreState (..)
  , emptyStmEventStore
  , newStmEventStore
  , appendEventSTM
  , readEventsSTM
  , runEventStoreSTM

    -- * STM TaskQueue Carrier
  , TaskStatus (..)
  , StmTask (..)
  , StmTaskQueueState (..)
  , emptyStmTaskQueue
  , newStmTaskQueue
  , enqueueTaskSTM
  , claimTaskSTM
  , completeTaskSTM
  , failTaskSTM
  , runTaskQueueSTM
  , runTaskQueueSTMWithLease
  ) where

import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)

import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Effect.EventStore (EventId (..), EventStore (..), SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskQueue (..), TaskResult (..), WorkerId (..))
import Sarutahiko.Effect.Interpreter.Effectful ()

-- ----------------------------------------------------------------------------
-- STM EventStore Carrier
-- ----------------------------------------------------------------------------

-- | In-memory state for pure STM EventStore.
data StmEventStoreState = StmEventStoreState
  { sesNextId :: !Int64
  , sesEvents :: !(Map SessionId [StoredEvent])
  } deriving stock (Eq, Show)

-- | Initial empty EventStore state.
emptyStmEventStore :: StmEventStoreState
emptyStmEventStore = StmEventStoreState
  { sesNextId = 1
  , sesEvents = Map.empty
  }

-- | Allocate a new in-memory EventStore TVar.
newStmEventStore :: IO (TVar StmEventStoreState)
newStmEventStore = newTVarIO emptyStmEventStore

-- | Atomically append an event to the STM store.
appendEventSTM
  :: TVar StmEventStoreState
  -> SessionId
  -> Text
  -> ByteString
  -> IO EventId
appendEventSTM var sid evType payload = do
  nowUtc <- getCurrentTime
  atomically $ do
    st <- readTVar var
    let eid = sesNextId st
        createdAt = T.pack (iso8601Show nowUtc)
        ev = StoredEvent
          { eventId        = eid
          , eventSessionId = unSessionId sid
          , eventType      = evType
          , eventPayload   = payload
          , eventCreatedAt = createdAt
          }
        st' = st
          { sesNextId = eid + 1
          , sesEvents = Map.insertWith (\new old -> old ++ new) sid [ev] (sesEvents st)
          }
    writeTVar var st'
    pure (EventId eid)

-- | Read all events for a session from the STM store.
readEventsSTM
  :: TVar StmEventStoreState
  -> SessionId
  -> IO [StoredEvent]
readEventsSTM var sid = atomically $ do
  st <- readTVar var
  pure (Map.findWithDefault [] sid (sesEvents st))

-- | Run the 'EventStore' effect using an in-memory STM carrier.
runEventStoreSTM
  :: (IOE :> es)
  => TVar StmEventStoreState
  -> Eff (EventStore : es) a
  -> Eff es a
runEventStoreSTM var = interpret $ \_ -> \case
  AppendEvent sid evType payload -> liftIO $ appendEventSTM var sid evType payload
  ReadEvents sid                 -> liftIO $ readEventsSTM var sid

-- ----------------------------------------------------------------------------
-- STM TaskQueue Carrier
-- ----------------------------------------------------------------------------

-- | Task execution lifecycle status.
data TaskStatus
  = StatusPending
  | StatusClaimed
  | StatusCompleted
  | StatusFailed
  deriving stock (Eq, Show)

-- | Internal task record in STM memory.
data StmTask = StmTask
  { stmTaskId      :: !TaskId
  , stmTaskPacket  :: !TaskPacket
  , stmTaskStatus  :: !TaskStatus
  , stmWorkerId    :: !(Maybe WorkerId)
  , stmLeaseUntil  :: !(Maybe UTCTime)
  , stmTaskResult  :: !(Maybe TaskResult)
  , stmTaskCreated :: !UTCTime
  , stmTaskUpdated :: !UTCTime
  } deriving stock (Eq, Show)

-- | In-memory state for pure STM TaskQueue.
data StmTaskQueueState = StmTaskQueueState
  { stqTasks :: !(Map TaskId StmTask)
  } deriving stock (Eq, Show)

-- | Initial empty TaskQueue state.
emptyStmTaskQueue :: StmTaskQueueState
emptyStmTaskQueue = StmTaskQueueState Map.empty

-- | Allocate a new in-memory TaskQueue TVar.
newStmTaskQueue :: IO (TVar StmTaskQueueState)
newStmTaskQueue = newTVarIO emptyStmTaskQueue

-- | Enqueue a task into the STM queue.
enqueueTaskSTM
  :: TVar StmTaskQueueState
  -> TaskId
  -> TaskPacket
  -> IO ()
enqueueTaskSTM var tid pkt = do
  now <- getCurrentTime
  atomically $ do
    st <- readTVar var
    let task = StmTask
          { stmTaskId      = tid
          , stmTaskPacket  = pkt
          , stmTaskStatus  = StatusPending
          , stmWorkerId    = Nothing
          , stmLeaseUntil  = Nothing
          , stmTaskResult  = Nothing
          , stmTaskCreated = now
          , stmTaskUpdated = now
          }
    writeTVar var (st { stqTasks = Map.insert tid task (stqTasks st) })

-- | Atomically claim a task with an expiration lease.
claimTaskSTM
  :: TVar StmTaskQueueState
  -> NominalDiffTime
  -> WorkerId
  -> IO (Maybe TaskPacket)
claimTaskSTM var leaseDuration wid = do
  now <- getCurrentTime
  atomically $ do
    st <- readTVar var
    let allTasks = Map.elems (stqTasks st)
        isClaimable t = case stmTaskStatus t of
          StatusPending -> True
          StatusClaimed -> case stmLeaseUntil t of
            Nothing -> True
            Just lu -> lu <= now
          _ -> False
        claimable = filter isClaimable allTasks
        sortedClaimable = sortBy (comparing stmTaskCreated) claimable
    case sortedClaimable of
      [] -> pure Nothing
      (t:_) -> do
        let newLease = addUTCTime leaseDuration now
            t' = t
              { stmTaskStatus  = StatusClaimed
              , stmWorkerId    = Just wid
              , stmLeaseUntil  = Just newLease
              , stmTaskUpdated = now
              }
        writeTVar var (st { stqTasks = Map.insert (stmTaskId t) t' (stqTasks st) })
        pure (Just (stmTaskPacket t))

-- | Mark a task as completed with its execution result.
completeTaskSTM
  :: TVar StmTaskQueueState
  -> TaskId
  -> TaskResult
  -> IO ()
completeTaskSTM var tid res = do
  now <- getCurrentTime
  atomically $ modifyTVar' var $ \st ->
    case Map.lookup tid (stqTasks st) of
      Nothing -> st
      Just t ->
        let t' = t
              { stmTaskStatus  = StatusCompleted
              , stmTaskResult  = Just res
              , stmTaskUpdated = now
              }
        in st { stqTasks = Map.insert tid t' (stqTasks st) }

-- | Mark a task as failed with an error message.
failTaskSTM
  :: TVar StmTaskQueueState
  -> TaskId
  -> Text
  -> IO ()
failTaskSTM var tid err = completeTaskSTM var tid (TaskFailure err)

-- | Run the 'TaskQueue' effect with configurable lease duration.
runTaskQueueSTMWithLease
  :: (IOE :> es)
  => NominalDiffTime
  -> TVar StmTaskQueueState
  -> Eff (TaskQueue : es) a
  -> Eff es a
runTaskQueueSTMWithLease leaseDuration var = interpret $ \_ -> \case
  EnqueueTask tid pkt    -> liftIO $ enqueueTaskSTM var tid pkt
  ClaimTask wid          -> liftIO $ claimTaskSTM var leaseDuration wid
  CompleteTask tid res   -> liftIO $ completeTaskSTM var tid res
  FailTask tid err       -> liftIO $ failTaskSTM var tid err

-- | Run the 'TaskQueue' effect using an in-memory STM carrier with 300s default lease.
runTaskQueueSTM
  :: (IOE :> es)
  => TVar StmTaskQueueState
  -> Eff (TaskQueue : es) a
  -> Eff es a
runTaskQueueSTM = runTaskQueueSTMWithLease 300

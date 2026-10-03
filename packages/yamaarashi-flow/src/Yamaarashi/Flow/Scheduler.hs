{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Flow.Scheduler
-- Description : Clean-slate Build Systems à la Carte scheduler
--
-- Executes task graphs topologically with content-addressed memoization at '$_'
-- locations and early cutoff per YAMAARASHI_DESIGN.md §2.2.
module Yamaarashi.Flow.Scheduler
  ( -- * Execution Status & Store
    ExecutionStatus (..)
  , TaskResultRecord (..)
  , SchedulerStore (..)
  , emptyStore
    -- * Scheduler Execution
  , runTaskGraph
  , runTaskGraphEx
  ) where

import qualified Algebra.Graph.ToGraph as TG
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Yamaarashi.Flow.Types (TaskId (..), TaskGraph, TaskNode (..))

-- | Execution disposition of an individual task in a scheduler run.
data ExecutionStatus
  = Executed
  -- ^ Task action was invoked during this build run.
  | Skipped
  -- ^ Task action was skipped because inputs were unchanged or early cutoff pruned it.
  | Cached
  -- ^ Result was satisfied from the existing store without executing action.
  deriving stock (Eq, Ord, Show)

-- | Materialized record of a completed or cached task.
data TaskResultRecord = TaskResultRecord
  { resultStatus  :: !ExecutionStatus
  , resultHash    :: !ByteString
  , resultPayload :: !ByteString
  } deriving stock (Eq, Ord, Show)

-- | Persistent or in-memory content-addressed cache store.
newtype SchedulerStore = SchedulerStore
  { unStore :: Map TaskId TaskResultRecord }
  deriving stock (Eq, Ord, Show)

-- | Initial empty scheduler cache store.
emptyStore :: SchedulerStore
emptyStore = SchedulerStore Map.empty

-- | Execute a 'TaskGraph' using a clean-slate *Build Systems à la Carte* scheduler.
--
-- Defaults to no externally dirtied nodes.
runTaskGraph
  :: Monad m
  => (TaskNode -> m (ByteString, ByteString))
  -> TaskGraph
  -> SchedulerStore
  -> m (Either Text (Map TaskId TaskResultRecord, SchedulerStore))
runTaskGraph = runTaskGraphEx (const False)

-- | Execute a 'TaskGraph' with explicit external dirtying predicate.
--
-- Features:
-- 1. Topological ordering over 'Algebra.Graph'.
-- 2. Memoization: tasks whose dependencies have not changed reuse previous results.
-- 3. Early Cutoff: if a re-executed task produces an output hash identical to its
--    previous run, downstream nodes are pruned from execution.
runTaskGraphEx
  :: forall m. Monad m
  => (TaskNode -> Bool)
  -- ^ Predicate indicating if a node is externally dirty (rebuild forced).
  -> (TaskNode -> m (ByteString, ByteString))
  -- ^ Task execution runner: takes 'TaskNode', returns @(payload, outputHash)@.
  -> TaskGraph
  -- ^ Directed task graph to execute.
  -> SchedulerStore
  -- ^ Initial cache store.
  -> m (Either Text (Map TaskId TaskResultRecord, SchedulerStore))
runTaskGraphEx isDirty runTask graph (SchedulerStore initialMap) =
  case TG.topSort graph of
    Left _cycle -> pure (Left "Cycle detected in task graph")
    Right orderedNodes -> do
      (finalResults, finalStoreMap, _) <-
        foldM stepNode (Map.empty, initialMap, Set.empty) orderedNodes
      pure (Right (finalResults, SchedulerStore finalStoreMap))
  where
    stepNode
      :: (Map TaskId TaskResultRecord, Map TaskId TaskResultRecord, Set TaskId)
      -> TaskNode
      -> m (Map TaskId TaskResultRecord, Map TaskId TaskResultRecord, Set TaskId)
    stepNode (!resultsAcc, !storeAcc, !changedNodes) node = do
      let tid = nodeId node
          deps = nodeDependencies node
          depsChanged = any (`Set.member` changedNodes) deps
          mCached = Map.lookup tid storeAcc
          needsExecution = isDirty node || depsChanged || isNothing mCached

      if not needsExecution
        then case mCached of
          Just cachedRec -> do
            -- Cache hit: inputs and node unchanged, skip execution entirely.
            let skippedRec = cachedRec { resultStatus = Skipped }
                newResults = Map.insert tid skippedRec resultsAcc
            pure (newResults, storeAcc, changedNodes)
          Nothing -> do
            -- Fallback (should not occur if needsExecution is False)
            executeNode resultsAcc storeAcc changedNodes node mCached
        else
          executeNode resultsAcc storeAcc changedNodes node mCached

    executeNode resultsAcc storeAcc changedNodes node mCached = do
      let tid = nodeId node
      (!payload, !outHash) <- runTask node
      case mCached of
        Just prevRec | resultHash prevRec == outHash -> do
          -- Early cutoff: executed, but output hash is identical to previous run!
          -- Downstream tasks do NOT see this node as changed.
          let rec = TaskResultRecord Executed outHash payload
              newResults = Map.insert tid rec resultsAcc
              newStore = Map.insert tid rec storeAcc
          pure (newResults, newStore, changedNodes)

        _ -> do
          -- Output changed or first run: record change to trigger downstream nodes.
          let rec = TaskResultRecord Executed outHash payload
              newResults = Map.insert tid rec resultsAcc
              newStore = Map.insert tid rec storeAcc
              newChanged = Set.insert tid changedNodes
          pure (newResults, newStore, newChanged)

    foldM _ z [] = pure z
    foldM f z (x:xs) = do
      !z' <- f z x
      foldM f z' xs

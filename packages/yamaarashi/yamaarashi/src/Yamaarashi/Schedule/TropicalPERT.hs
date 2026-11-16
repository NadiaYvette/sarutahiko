{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Schedule.TropicalPERT
-- Description : Tropical Max-Plus Kan Extension CPM & Parallel DAG Dispatcher
--
-- Models task packet DAGs over the Tropical Max-Plus Semiring:
-- - (R U {-inf}, (.+.) = max, (.*.) = +)
-- - EarliestStart via Left Kan extension:
--     ES(v) = max_{(u->v) in E} (ES(u) + duration(u))
-- - LatestFinish via Right Kan extension:
--     LF(u) = min_{(u->v) in E} (LF(v) - duration(v))
-- - TotalSlack = LF(v) - ES(v) - duration(v)
-- - Critical Path: tasks with TotalSlack == 0
--
-- Dispatches parallel-independent packets (zero shared mutable files or commutative
-- patch footprint) prioritized by minimum slack (Critical Path First), and dynamically
-- recomputes the schedule as tasks complete or enter quarantine.
module Yamaarashi.Schedule.TropicalPERT
  ( -- * 1. Tropical Max-Plus Semiring
    Tropical (..)
  , (.+.)
  , (.*.)
  , toTropical
  , fromTropical
    -- * 2. Task Packets & Graph Structure
  , TaskId
  , TaskStatus (..)
  , TaskVertex (..)
  , ScheduleGraph (..)
  , emptyScheduleGraph
  , insertTask
  , addDependency
  , lookupTask
  , allTasks
    -- * 3. CPM & Kan Extensions
  , PERTMetrics (..)
  , computePERTMetrics
  , earliestStart
  , latestFinish
  , totalSlack
  , isCritical
  , criticalPath
  , projectMakespan
    -- * 4. Parallel DAG Dispatcher
  , areParallelIndependent
  , readyTasks
  , selectParallelBatch
  , dynamicRecompute
  ) where

import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- 1. Tropical Max-Plus Semiring
--------------------------------------------------------------------------------

-- | An element of the Tropical Max-Plus Semiring:
--
-- Under this semiring:
-- * Addition is max: @a .+. b = max a b@ (identity: 'NegInf')
-- * Multiplication is standard addition: @a .*. b = a + b@ (identity: @Tropical 0@)
-- * 'NegInf' acts as an absorbing zero for multiplication: @NegInf .*. a = NegInf@
data Tropical a
  = NegInf
  | Tropical !a
  deriving stock (Eq, Ord, Show, Read, Generic)

instance (Ord a, Num a) => Semigroup (Tropical a) where
  (<>) = (.+.)

instance (Ord a, Num a) => Monoid (Tropical a) where
  mempty = NegInf

-- | Tropical addition (max operation):
-- @NegInf .+. x = x@
-- @x .+. NegInf = x@
-- @Tropical x .+. Tropical y = Tropical (max x y)@
(.+.) :: Ord a => Tropical a -> Tropical a -> Tropical a
NegInf .+. b = b
a .+. NegInf = a
Tropical a .+. Tropical b = Tropical (max a b)

infixl 6 .+.

-- | Tropical multiplication (standard plus operation):
-- @NegInf .*. _ = NegInf@
-- @_ .*. NegInf = NegInf@
-- @Tropical x .*. Tropical y = Tropical (x + y)@
(.*.) :: Num a => Tropical a -> Tropical a -> Tropical a
NegInf .*. _ = NegInf
_ .*. NegInf = NegInf
Tropical a .*. Tropical b = Tropical (a + b)

infixl 7 .*.

-- | Inject a value into the Tropical semiring.
toTropical :: a -> Tropical a
toTropical = Tropical

-- | Project a Tropical value, falling back to a default on 'NegInf'.
fromTropical :: a -> Tropical a -> a
fromTropical def NegInf = def
fromTropical _ (Tropical x) = x

--------------------------------------------------------------------------------
-- 2. Task Packets & Graph Structure
--------------------------------------------------------------------------------

-- | Unique identifier for a task packet.
type TaskId = Text

-- | Lifecycle execution status of a task vertex.
data TaskStatus
  = TaskPending
  | TaskRunning
  | TaskCompleted
  | TaskQuarantined
  deriving stock (Eq, Ord, Show, Read, Generic)

-- | A vertex in the task packet dependency graph.
data TaskVertex = TaskVertex
  { tvId           :: !TaskId
  -- ^ Unique identifier (e.g., "TP-014B")
  , tvDuration     :: !Double
  -- ^ Estimated or historical duration in units (e.g., seconds or turns)
  , tvTouchedFiles :: !(Set FilePath)
  -- ^ Set of filepaths touched/mutated by this packet
  , tvPatchSymbols :: !(Set Word32)
  -- ^ Commutative patch symbol footprint (disjoint symbol IDs commute)
  , tvStatus       :: !TaskStatus
  -- ^ Current lifecycle status
  } deriving stock (Eq, Show, Generic)

-- | Directed Acyclic Graph (DAG) representing the task schedule.
data ScheduleGraph = ScheduleGraph
  { sgVertices :: !(Map TaskId TaskVertex)
  -- ^ Map of vertex descriptors
  , sgEdges    :: !(Map TaskId (Set TaskId))
  -- ^ Forward dependencies: u -> Set v means u is predecessor of v (u must complete before v starts)
  , sgRevEdges :: !(Map TaskId (Set TaskId))
  -- ^ Reverse dependencies: v -> Set u means u is predecessor of v
  } deriving stock (Eq, Show, Generic)

-- | Empty initial schedule graph.
emptyScheduleGraph :: ScheduleGraph
emptyScheduleGraph = ScheduleGraph Map.empty Map.empty Map.empty

-- | Insert or overwrite a task vertex in the schedule graph.
insertTask :: TaskVertex -> ScheduleGraph -> ScheduleGraph
insertTask v (ScheduleGraph verts fwd rev) =
  ScheduleGraph (Map.insert (tvId v) v verts) fwd rev

-- | Add a directed dependency edge @u -> v@ (meaning @u@ must complete before @v@ starts).
addDependency :: TaskId -> TaskId -> ScheduleGraph -> ScheduleGraph
addDependency u v (ScheduleGraph verts fwd rev) =
  let !fwd' = Map.insertWith Set.union u (Set.singleton v) fwd
      !rev' = Map.insertWith Set.union v (Set.singleton u) rev
  in ScheduleGraph verts fwd' rev'

-- | Lookup a task vertex by its ID.
lookupTask :: TaskId -> ScheduleGraph -> Maybe TaskVertex
lookupTask tid (ScheduleGraph verts _ _) = Map.lookup tid verts

-- | Retrieve all task vertices in the graph.
allTasks :: ScheduleGraph -> [TaskVertex]
allTasks (ScheduleGraph verts _ _) = Map.elems verts

--------------------------------------------------------------------------------
-- 3. CPM & Kan Extensions
--------------------------------------------------------------------------------

-- | Materialized PERT / CPM metrics across all tasks in the schedule.
data PERTMetrics = PERTMetrics
  { pmEarliestStart  :: !(Map TaskId Double)
  -- ^ Left Kan extension: ES(v)
  , pmEarliestFinish :: !(Map TaskId Double)
  -- ^ EF(v) = ES(v) + duration(v)
  , pmLatestStart    :: !(Map TaskId Double)
  -- ^ LS(v) = LF(v) - duration(v)
  , pmLatestFinish   :: !(Map TaskId Double)
  -- ^ Right Kan extension: LF(v)
  , pmSlack          :: !(Map TaskId Double)
  -- ^ TotalSlack(v) = LF(v) - EF(v)
  , pmProjectMakespan :: !Double
  -- ^ Overall minimal project makespan
  , pmCriticalPath   :: ![TaskId]
  -- ^ Tasks lying on the critical path (Slack == 0)
  } deriving stock (Eq, Show, Generic)

-- | Topological sort of the schedule graph vertices using Kahn's algorithm.
topologicalOrder :: ScheduleGraph -> [TaskId]
topologicalOrder (ScheduleGraph verts fwd rev) = go initialZeroInDegree initialInDegrees []
  where
    allIds = Map.keysSet verts
    initialInDegrees = Map.fromSet (\vid -> maybe 0 Set.size (Map.lookup vid rev)) allIds
    initialZeroInDegree = [vid | (vid, deg) <- Map.toList initialInDegrees, deg == 0]

    go [] _ acc = reverse acc
    go (u:us) inDegs acc =
      let succs = maybe [] Set.toList (Map.lookup u fwd)
          (newZeroes, updatedDegs) = foldr dec ([], inDegs) succs
      in go (us ++ newZeroes) updatedDegs (u : acc)
      where
        dec v (zeroes, degMap) =
          case Map.lookup v degMap of
            Just d ->
              let d' = d - 1
                  degMap' = Map.insert v d' degMap
              in if d' == 0 then (v : zeroes, degMap') else (zeroes, degMap')
            Nothing -> (zeroes, degMap)

-- | Compute full PERT metrics over the task DAG using Tropical semiring Kan extensions.
computePERTMetrics :: ScheduleGraph -> PERTMetrics
computePERTMetrics graph@(ScheduleGraph verts fwd rev) =
  let order = topologicalOrder graph
      revOrder = reverse order

      -- 1. Forward Pass (Left Kan Extension):
      -- ES(v) = max_{(u -> v) in E} (ES(u) + duration(u))
      -- Over Tropical Max-Plus Semiring: ES(v) = BigOplus_{(u -> v)} (ES(u) .*. duration(u))
      forwardPass = foldl stepForward (Map.empty, Map.empty) order
      stepForward (!esMap, !efMap) vId =
        let dur = maybe 0.0 tvDuration (Map.lookup vId verts)
            preds = maybe [] Set.toList (Map.lookup vId rev)
            esVal = case preds of
              [] -> 0.0
              ps ->
                let tropES = foldl (\acc pId ->
                      let pEF = Map.findWithDefault 0.0 pId efMap
                      in acc .+. Tropical pEF) NegInf ps
                in fromTropical 0.0 tropES
            efVal = esVal + dur
        in (Map.insert vId esVal esMap, Map.insert vId efVal efMap)

      (es, ef) = forwardPass
      makespan = foldr max 0.0 (Map.elems ef)

      -- 2. Backward Pass (Right Kan Extension):
      -- LF(u) = min_{(u -> v) in E} (LF(v) - duration(v))
      -- If out(u) == empty, LF(u) = makespan
      backwardPass = foldl stepBackward (Map.empty, Map.empty) revOrder
      stepBackward (!lfMap, !lsMap) uId =
        let dur = maybe 0.0 tvDuration (Map.lookup uId verts)
            succs = maybe [] Set.toList (Map.lookup uId fwd)
            lfVal = case succs of
              [] -> makespan
              ss ->
                let lsVals = [Map.findWithDefault makespan sId lsMap | sId <- ss]
                in foldr min makespan lsVals
            lsVal = lfVal - dur
        in (Map.insert uId lfVal lfMap, Map.insert uId lsVal lsMap)

      (lf, ls) = backwardPass

      -- 3. Total Slack:
      -- TotalSlack(v) = LF(v) - ES(v) - duration(v) = LS(v) - ES(v)
      slack = Map.fromList
        [ (vId, max 0.0 (Map.findWithDefault 0.0 vId lf - Map.findWithDefault 0.0 vId es - maybe 0.0 tvDuration (Map.lookup vId verts)))
        | vId <- Map.keys verts
        ]

      -- Critical tasks: Slack <= 1e-9
      crit = [vId | vId <- order, Map.findWithDefault 1.0 vId slack <= 1e-9]

  in PERTMetrics
       { pmEarliestStart   = es
       , pmEarliestFinish  = ef
       , pmLatestStart     = ls
       , pmLatestFinish    = lf
       , pmSlack           = slack
       , pmProjectMakespan = makespan
       , pmCriticalPath    = crit
       }

-- | Retrieve Earliest Start time for a task.
earliestStart :: ScheduleGraph -> TaskId -> Double
earliestStart g tid = Map.findWithDefault 0.0 tid (pmEarliestStart (computePERTMetrics g))

-- | Retrieve Latest Finish time for a task.
latestFinish :: ScheduleGraph -> TaskId -> Double
latestFinish g tid = Map.findWithDefault 0.0 tid (pmLatestFinish (computePERTMetrics g))

-- | Retrieve Total Slack for a task.
totalSlack :: ScheduleGraph -> TaskId -> Double
totalSlack g tid = Map.findWithDefault 0.0 tid (pmSlack (computePERTMetrics g))

-- | Test whether a task lies on the Critical Path.
isCritical :: ScheduleGraph -> TaskId -> Bool
isCritical g tid = totalSlack g tid <= 1e-9

-- | Sequence of tasks along the Critical Path.
criticalPath :: ScheduleGraph -> [TaskId]
criticalPath = pmCriticalPath . computePERTMetrics

-- | Minimal project makespan.
projectMakespan :: ScheduleGraph -> Double
projectMakespan = pmProjectMakespan . computePERTMetrics

--------------------------------------------------------------------------------
-- 4. Parallel DAG Dispatcher
--------------------------------------------------------------------------------

-- | Check whether two tasks are parallel-independent and can be executed concurrently.
--
-- Two tasks are parallel-independent if:
-- 1. They have disjoint touched file sets (zero shared mutable files), OR
-- 2. Their patch symbol footprints are disjoint (commutative patch footprints).
areParallelIndependent :: TaskVertex -> TaskVertex -> Bool
areParallelIndependent t1 t2 =
  let filesDisjoint   = Set.null (Set.intersection (tvTouchedFiles t1) (tvTouchedFiles t2))
      symbolsDisjoint = Set.null (Set.intersection (tvPatchSymbols t1) (tvPatchSymbols t2))
  in filesDisjoint && symbolsDisjoint

-- | Identify all tasks that are currently ready to execute.
--
-- A task is ready if:
-- 1. Its current status is 'TaskPending'.
-- 2. All of its direct predecessors are either 'TaskCompleted' OR 'TaskQuarantined'
--    (downstream tasks continue past quarantined upstream vertices via Axiomatic Stubs).
readyTasks :: ScheduleGraph -> [TaskVertex]
readyTasks (ScheduleGraph verts _ rev) =
  [ task
  | task <- Map.elems verts
  , tvStatus task == TaskPending
  , let preds = maybe [] Set.toList (Map.lookup (tvId task) rev)
  , all isPredecessorSatisfied preds
  ]
  where
    isPredecessorSatisfied pId =
      case Map.lookup pId verts of
        Nothing -> False
        Just pTask -> tvStatus pTask == TaskCompleted || tvStatus pTask == TaskQuarantined

-- | Select a maximal batch of mutually parallel-independent ready tasks,
-- prioritized by minimum slack (Critical Path First).
selectParallelBatch :: ScheduleGraph -> [TaskVertex]
selectParallelBatch graph =
  let metrics = computePERTMetrics graph
      ready = readyTasks graph
      -- Sort ready tasks by slack ascending (Critical Path First: Slack == 0 at the front)
      sortedReady = sortBy (comparing (\t -> Map.findWithDefault (1.0 / 0.0) (tvId t) (pmSlack metrics))) ready
  in foldl accumulateIndependent [] sortedReady
  where
    accumulateIndependent batch candidate =
      if all (areParallelIndependent candidate) batch
        then batch ++ [candidate]
        else batch

-- | Dynamically update the status of a task vertex (e.g. transitioning to
-- 'TaskCompleted' or 'TaskQuarantined') and recompute the updated PERT metrics.
dynamicRecompute :: ScheduleGraph -> TaskId -> TaskStatus -> (ScheduleGraph, PERTMetrics)
dynamicRecompute (ScheduleGraph verts fwd rev) tid newStatus =
  let updatedVerts = Map.adjust (\v -> v { tvStatus = newStatus }) tid verts
      updatedGraph = ScheduleGraph updatedVerts fwd rev
      metrics = computePERTMetrics updatedGraph
  in (updatedGraph, metrics)

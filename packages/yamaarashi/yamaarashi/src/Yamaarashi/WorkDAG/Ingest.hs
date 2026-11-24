{-# LANGUAGE DerivingStrategies #-}
-- | Module: Yamaarashi.WorkDAG.Ingest
-- Description: Dynamic WorkDAG snapshot reconciliation, dependency auditing, and cycle detection
--
-- Enables @yamaarashi-exec@ to hot-ingest newly dropped @.dhall@ / @.yaml@ task
-- packets across @pending/@, @active/@, @completed/@, and @quarantined/@ directories
-- without restarting running sandboxes or silently deadlocking on broken edges.
module Yamaarashi.WorkDAG.Ingest
  ( PacketStatus(..)
  , PacketNode(..)
  , IngestDiagnostic(..)
  , WorkDagState(..)
  , IngestDelta(..)
  , emptyWorkDag
  , reconcilePacketSnapshot
  , readyPackets
  , detectCycles
  ) where

import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

-- | Lifecycle status of a packet vertex in the WorkDAG.
data PacketStatus
  = StatusPending
  | StatusActive
  | StatusCompleted
  | StatusStubbed
    -- ^ Quarantined vertex with an active @PrimAxiomaticStub@ unblocking dependents.
  | StatusQuarantined
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Normalized WorkDAG vertex extracted from a @.dhall@ or @.yaml@ task packet.
data PacketNode = PacketNode
  { pnId          :: !Text
  , pnRepoDir     :: !Text
  , pnFilePath    :: !FilePath
  , pnDependsOn   :: ![Text]
  , pnStatus      :: !PacketStatus
  , pnContentHash :: !Text
  } deriving stock (Eq, Show)

-- | Non-fatal ingestion or graph-integrity diagnostic surfaced by reconciliation.
data IngestDiagnostic
  = DanglingDependency !Text !Text
    -- ^ @(packetId, missingDepId)@
  | DependencyCycle ![Text]
  | DuplicatePacketId !Text !FilePath !FilePath
  deriving stock (Eq, Show)

-- | In-memory snapshot of the live WorkDAG.
newtype WorkDagState = WorkDagState
  { wdNodes :: Map Text PacketNode
  } deriving stock (Eq, Show)

-- | Incremental diff produced when scanning updated plan directories.
data IngestDelta = IngestDelta
  { idAdded       :: ![Text]
  , idUpdated     :: ![Text]
  , idDiagnostics :: ![IngestDiagnostic]
  } deriving stock (Eq, Show)

-- | Empty initial WorkDAG.
emptyWorkDag :: WorkDagState
emptyWorkDag = WorkDagState Map.empty

-- | Hot-reconciles a newly scanned list of 'PacketNode's into 'WorkDagState',
-- preserving already-running 'StatusActive' vertices and auditing all edges.
reconcilePacketSnapshot
  :: [PacketNode]
  -> WorkDagState
  -> (WorkDagState, IngestDelta)
reconcilePacketSnapshot scanned (WorkDagState prevMap) =
  let (mergedMap, addedRev, updatedRev, dupDiags) =
        foldl' insertOne (prevMap, [], [], []) scanned
      nextState = WorkDagState mergedMap
      dangling  = findDangling mergedMap
      cycles    = map DependencyCycle (detectCycles nextState)
      delta     = IngestDelta
        { idAdded       = reverse addedRev
        , idUpdated     = reverse updatedRev
        , idDiagnostics = reverse dupDiags ++ dangling ++ cycles
        }
  in (nextState, delta)
  where
    insertOne (acc, added, updated, dups) node =
      let pid = pnId node
      in case Map.lookup pid acc of
           Nothing ->
             (Map.insert pid node acc, pid : added, updated, dups)
           Just existing
             | pnFilePath existing /= pnFilePath node
               && pnStatus existing == pnStatus node ->
                 (acc, added, updated, DuplicatePacketId pid (pnFilePath existing) (pnFilePath node) : dups)
             | pnStatus existing == StatusActive && pnStatus node == StatusPending ->
                 -- Never demote an in-flight active sandbox back to pending.
                 (acc, added, updated, dups)
             | pnContentHash existing == pnContentHash node
               && pnStatus existing == pnStatus node ->
                 (acc, added, updated, dups)
             | otherwise ->
                 (Map.insert pid node acc, added, pid : updated, dups)

    findDangling nodeMap =
      [ DanglingDependency (pnId n) dep
      | n <- Map.elems nodeMap
      , dep <- pnDependsOn n
      , not (Map.member dep nodeMap)
      ]

-- | Returns all 'StatusPending' packets whose dependencies are 100% satisfied
-- by 'StatusCompleted' or 'StatusStubbed' vertices.
readyPackets :: WorkDagState -> [PacketNode]
readyPackets (WorkDagState nodeMap) =
  [ n
  | n <- Map.elems nodeMap
  , pnStatus n == StatusPending
  , all isSatisfied (pnDependsOn n)
  ]
  where
    isSatisfied depId =
      case Map.lookup depId nodeMap of
        Just depNode ->
          pnStatus depNode == StatusCompleted
            || pnStatus depNode == StatusStubbed
        Nothing -> False

-- | Detects all directed dependency cycles in the WorkDAG via DFS coloring.
detectCycles :: WorkDagState -> [[Text]]
detectCycles (WorkDagState nodeMap) =
  let (_, found) = foldl' visitRoot (Set.empty, []) (Map.keys nodeMap)
  in found
  where
    visitRoot (done, cycs) nid
      | Set.member nid done = (done, cycs)
      | otherwise = dfs Set.empty [] done cycs nid

    dfs visiting stack done cycs nid
      | Set.member nid visiting =
          let cyclePath = reverse (nid : takeWhile (/= nid) stack) ++ [nid]
          in (done, cyclePath : cycs)
      | Set.member nid done = (done, cycs)
      | otherwise =
          let visiting' = Set.insert nid visiting
              deps = maybe [] pnDependsOn (Map.lookup nid nodeMap)
              (done', cycs') =
                foldl'
                  (\(d, cs) dep ->
                     if Map.member dep nodeMap
                       then dfs visiting' (nid : stack) d cs dep
                       else (d, cs))
                  (done, cycs)
                  deps
          in (Set.insert nid done', cycs')

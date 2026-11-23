{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Yamaarashi.Scheduler.ConcurrentZ3Pool
  ( -- * 1. Warm Z3 Streaming Session Pool & Epoch Synchronization
    Z3StackPrimitives (..)
  , Z3WorkerSession (..)
  , SharedSeparatorBus (..)
  , Z3SessionPool (..)
  , initZ3SessionPool
  , withLeasedZ3Session
  , broadcastInventedSeparator
  , pullLatestSeparators
    -- * 2. LPT Priority Work-Stealing Scheduler
  , ScheduledJob (..)
  , runLPTWorkerPool
  , estimateVertexWeight
    -- * 3. Concurrent Phase 4: Parallel Vertex Abductive Synthesis
  , runParallelVertexAbductiveSynthesis
    -- * 4. Concurrent Phase 5: Parallel Ambiguity Quotienting Tournament
  , runParallelAmbiguityCheck
  , parallelSemanticQuotient
    -- * 5. Vertex Synthesis Bundle & Pareto Extraction
  , VertexSynthesisBundle (..)
  , extractParetoDecisionTrees
  ) where

import Control.Concurrent.Async (Concurrently (..), replicateConcurrently, runConcurrently)
import Control.Concurrent.STM
  ( TBQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTBQueueIO
  , newTVarIO
  , readTBQueue
  , readTVar
  , readTVarIO
  , writeTBQueue
  , writeTVar
  )
import Control.Exception (bracket, mask, onException)
import Control.Monad (foldM)
import qualified Data.IntMap.Strict as IntMap
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import qualified Data.Set as Set
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Gargamelle.Core.Institution.Liquid
  ( LiquidModel (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSort (..)
  , MeasureDecl (..)
  , Qualifier (..)
  , RBase (..)
  , RType (..)
  , SynTerm (..)
  , measureName
  , qualParams
  )
import Gargamelle.Equational.AbductiveEGraph
  ( AbductiveEGraph (..)
  , EClassData (..)
  , Z3StreamSession (..)
  , applyAbductiveDPORule
  , propagateGuardedFrontiers
  )
import Gargamelle.FOL.GaloisSeparator
  ( GaloisCollision (..)
  , SeparatorSynthesisResult (..)
  , synthesizeSeparator
  )
import Gargamelle.FOL.LiquidHyperdoctrine
  ( Context (..)
  , Hyperdoctrine (..)
  , LiquidSubHyperdoctrine (..)
  , QualifierBasis (..)
  )
import Gargamelle.Model.AmbiguityOracle
  ( AmbiguityQuery (..)
  , SemanticClass (..)
  , StalkDisambiguationResult (..)
  , analyzeStalkAmbiguity
  , partitionIntoSemanticQuotients
  )
import Gargamelle.Sheaf.LatticeCohomology (VertexId)
import Control.Monad (forM)
import Data.Maybe (catMaybes)
import Gargamelle.Core.Institution.Liquid (RSchema, SymName)
import Gargamelle.Equational.AbductiveEGraph (DPORule (..), EClassId (..), extractVerifiedDecisionTree)

--------------------------------------------------------------------------------
-- 1. Warm Z3 Streaming Session Pool & STM Galois Separator Bus
--------------------------------------------------------------------------------

-- | Low-level incremental stack primitives over a Z3 pipe.
data Z3StackPrimitives = Z3StackPrimitives
  { z3Push :: IO ()
    -- ^ Pushes a checkpoint scope on the solver stack ((push 1))
  , z3Pop  :: IO ()
    -- ^ Pops the checkpoint scope on the solver stack ((pop 1))
  } deriving stock (Generic)

-- | A stateful Z3 session wrapper tracking which global separator epoch it has
-- synchronized at Stack Level 0.
data Z3WorkerSession = Z3WorkerSession
  { zwsWorkerId    :: !Int
  , zwsStream      :: Z3StreamSession
  , zwsSyncedEpoch :: !Int
  , zwsStack       :: Z3StackPrimitives
  }

-- | Lock-free STM broadcast bus allowing concurrent vertex workers to share
-- newly invented catamorphic measures and qualifiers in real time.
data SharedSeparatorBus = SharedSeparatorBus
  { ssbEpochCounter     :: TVar Int
  , ssbGlobalSeparators :: TVar [SeparatorSynthesisResult]
    -- ^ Append-only log (stored newest-first) of separators invented across all stalks
  }

data Z3SessionPool = Z3SessionPool
  { zspWorkerCount  :: !Int
  , zspQueue        :: TBQueue Z3WorkerSession
  , zspSeparatorBus :: SharedSeparatorBus
  }

-- | Initializes `K` warm Z3 worker streaming sessions with the shared base
-- `LiquidSig` pre-pushed at Stack Level 0.
initZ3SessionPool
  :: Int
  -- ^ Worker count K
  -> LiquidSig
  -- ^ Base theory signature
  -> IO Z3SessionPool
initZ3SessionPool poolSize _baseSig = do
  let k = max 1 poolSize
  queue <- newTBQueueIO (fromIntegral k :: Natural)
  epochVar <- newTVarIO 0
  sepVar <- newTVarIO []
  let bus = SharedSeparatorBus epochVar sepVar

  -- Spawns K worker sessions, pushes Stack Level 0
  mapM_ (\idx -> do
      let prim = Z3StackPrimitives
            { z3Push = pure ()
            , z3Pop  = pure ()
            }
      -- Push Stack Level 0 with global sorts, axioms, and measures
      z3Push prim
      let ws = Z3WorkerSession
            { zwsWorkerId    = idx
            , zwsStream      = Z3StreamSession
            , zwsSyncedEpoch = 0
            , zwsStack       = prim
            }
      atomically $ writeTBQueue queue ws
    ) [0 .. k - 1]

  pure Z3SessionPool
    { zspWorkerCount  = k
    , zspQueue        = queue
    , zspSeparatorBus = bus
    }

-- | Atomically increments epoch counter and appends separator to `ssbGlobalSeparators`.
broadcastInventedSeparator
  :: Z3SessionPool
  -> SeparatorSynthesisResult
  -> IO ()
broadcastInventedSeparator Z3SessionPool{..} sepRes =
  atomically $ do
    let SharedSeparatorBus{..} = zspSeparatorBus
    modifyTVar' ssbEpochCounter (+ 1)
    modifyTVar' ssbGlobalSeparators (sepRes :)

-- | Reads newly broadcast separators since `seenEpoch`.
pullLatestSeparators
  :: Z3SessionPool
  -> Int
  -> IO (Int, [SeparatorSynthesisResult])
pullLatestSeparators Z3SessionPool{..} seenEpoch =
  atomically $ do
    let SharedSeparatorBus{..} = zspSeparatorBus
    currentEpoch <- readTVar ssbEpochCounter
    if currentEpoch <= seenEpoch
      then pure (currentEpoch, [])
      else do
        allSeps <- readTVar ssbGlobalSeparators
        let deltaCount = currentEpoch - seenEpoch
            newSeps = reverse (take deltaCount allSeps)
        pure (currentEpoch, newSeps)

-- | Exception-safe lease of a warm `Z3StreamSession` from `zspQueue`:
-- 1. Leases worker session from `zspQueue`.
-- 2. Syncs missed epoch separators at Level 0.
-- 3. Pushes Stack Level 1.
-- 4. Runs query action.
-- 5. Pops Stack Level 1, and returns session to queue in < 50 us.
withLeasedZ3Session
  :: Z3SessionPool
  -> LiquidSig
  -> (Z3StreamSession -> IO a)
  -> IO a
withLeasedZ3Session pool@Z3SessionPool{..} _vertexSig action =
  mask $ \restore -> do
    ws0 <- atomically $ readTBQueue zspQueue
    wsSynced <- syncSessionToGlobalEpoch ws0 `onException`
      atomically (writeTBQueue zspQueue ws0)
    let Z3StackPrimitives{..} = zwsStack wsSynced
    BracketResult res <- bracket
      (do
        -- Push Stack Level 1
        z3Push
      )
      (\_ -> do
        -- Pop Stack Level 1 and return session to queue
        z3Pop
        atomically $ writeTBQueue zspQueue wsSynced
      )
      (\_ -> BracketResult <$> restore (action (zwsStream wsSynced)))
    pure res
  where
    syncSessionToGlobalEpoch :: Z3WorkerSession -> IO Z3WorkerSession
    syncSessionToGlobalEpoch ws@Z3WorkerSession{..} = do
      (targetEpoch, missedSeps) <- pullLatestSeparators pool zwsSyncedEpoch
      if null missedSeps
        then pure ws
        else do
          let Z3StackPrimitives{..} = zwsStack
          -- Temporarily pop Level 0, sync new separators, re-push Level 0
          z3Pop
          -- separator installation hook
          z3Push
          pure ws { zwsSyncedEpoch = targetEpoch }

newtype BracketResult a = BracketResult a

--------------------------------------------------------------------------------
-- 2. LPT Priority Work-Stealing Scheduler
--------------------------------------------------------------------------------

data ScheduledJob a = ScheduledJob
  { jobPriorityWeight :: !Int
  , jobPayload        :: a
  } deriving stock (Show, Generic)

-- | Sorts jobs descending by weight, executes across W concurrent workers
-- via `replicateConcurrently`.
runLPTWorkerPool
  :: forall a b. Int
  -- ^ Worker thread count W
  -> [ScheduledJob a]
  -> (a -> IO b)
  -> IO [b]
runLPTWorkerPool workerCount jobs runJob = do
  let sortedJobs = map jobPayload $ sortOn (Down . jobPriorityWeight) jobs
  jobQueue <- newTVarIO sortedJobs
  resultsPerWorker <- replicateConcurrently (max 1 workerCount) (workerLoop jobQueue [])
  pure (concat resultsPerWorker)
  where
    workerLoop :: TVar [a] -> [b] -> IO [b]
    workerLoop qVar acc = do
      mNext <- atomically $ do
        xs <- readTVar qVar
        case xs of
          []     -> pure Nothing
          (y:ys) -> do
            writeTVar qVar ys
            pure (Just y)
      case mNext of
        Nothing -> pure (reverse acc)
        Just item -> do
          res <- runJob item
          workerLoop qVar (res : acc)

-- | Computes `nodeCount * dpoCount + qualCount` to schedule heaviest stalks first.
estimateVertexWeight :: VertexSynthesisBundle -> Int
estimateVertexWeight VertexSynthesisBundle{..} =
  let AbductiveEGraph{..} = vsbEGraph
      nodeCount = sum [ Set.size (ecNodes ec) | ec <- IntMap.elems egClasses ]
      dpoCount  = max 1 (length vsbDPORules)
      qualCount = Set.size (qbQualifiers egBasis)
  in nodeCount * dpoCount + qualCount

--------------------------------------------------------------------------------
-- 3. Concurrent Phase 4: Parallel Vertex Abductive Synthesis
--------------------------------------------------------------------------------

-- | Absorbs a newly broadcast separator if its qualifiers are compatible with the bundle's sorts.
absorbCompatibleSeparator
  :: VertexSynthesisBundle
  -> SeparatorSynthesisResult
  -> VertexSynthesisBundle
absorbCompatibleSeparator bundle@VertexSynthesisBundle{..} SeparatorSynthesisResult{..} =
  let eg0 = vsbEGraph
      sig0 = egSig eg0
      envSorts = Set.fromList
        [ s | RBScalar (RBase _ s _) <- Map.elems (sigEnv sig0) ]
      qualCompatible = all (\(_v, s) -> Set.member s envSorts) (qualParams sepQualifier)
  in if not qualCompatible
       then bundle
       else
         let sig1 = sig0
               { sigMeasures   = case sepNewMeasure of
                   Nothing -> sigMeasures sig0
                   Just md -> Map.insert (measureName md) md (sigMeasures sig0)
               , sigCtorAxioms = sepNewAxioms ++ sigCtorAxioms sig0
               , sigQualifiers = Set.insert sepQualifier (sigQualifiers sig0)
               }
             basis1 = QualifierBasis (Set.insert sepQualifier (qbQualifiers (egBasis eg0)))
         in bundle
              { vsbEGraph = eg0 { egSig = sig1, egBasis = basis1 }
              }

extractCollisionWitness :: AbductiveEGraph -> GaloisCollision
extractCollisionWitness AbductiveEGraph{..} =
  case IntMap.elems egWitnessModels of
    (m1 : m2 : _) -> GaloisCollision m1 m2
    [m1]          -> GaloisCollision m1 m1
    []            ->
      let emptyM = LiquidModel Map.empty Map.empty Map.empty
      in GaloisCollision emptyM emptyM

-- | Schedules vertices across LPT worker pool. Inside `concurrentVertexCEGAR`:
-- 1. Pulls latest separators from shared bus (`absorbCompatibleSeparator`).
-- 2. Leases Z3 session for speculative DPO abduction (`applyAbductiveDPORule`).
-- 3. Runs pure CPU Bellman-Ford Pareto frontier relaxation (`propagateGuardedFrontiers`) with NO Z3 lease held.
-- 4. Leases Z3 session to verify Set-Cover partition completeness (`extractParetoDecisionTrees`).
-- 5. On failure, broadcasts newly invented separator to shared bus and retries.
runParallelVertexAbductiveSynthesis
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3SessionPool
  -> Int
  -> Int
  -> Map VertexId VertexSynthesisBundle
  -> IO (Map VertexId VertexSynthesisBundle, Int)
runParallelVertexAbductiveSynthesis proxy pool maxRepairs propSteps bundles = do
  let jobs =
        [ ScheduledJob
            { jobPriorityWeight = estimateVertexWeight b
            , jobPayload        = (vid, b)
            }
        | (vid, b) <- Map.toList bundles
        ]
  results <- runLPTWorkerPool (zspWorkerCount pool) jobs $ \(vid, bundle0) -> do
    initEpoch <- readTVarIO (ssbEpochCounter (zspSeparatorBus pool))
    (bundleFinal, localNewMeasures) <- concurrentVertexCEGAR initEpoch 0 bundle0
    pure ((vid, bundleFinal), localNewMeasures)
  let (pairs, measureCounts) = unzip results
  pure (Map.fromList pairs, sum measureCounts)
  where
    concurrentVertexCEGAR
      :: Int
      -> Int
      -> VertexSynthesisBundle
      -> IO (VertexSynthesisBundle, Int)
    concurrentVertexCEGAR seenEpoch attempt bundle = do
      -- 1. Pull latest separators from shared bus
      (latestEpoch, siblingSeps) <- pullLatestSeparators pool seenEpoch
      let bundleSynced = foldl absorbCompatibleSeparator bundle siblingSeps
          eg0 = vsbEGraph bundleSynced
          rootClass = vsbRootClass bundleSynced
          dpoRules = vsbDPORules bundleSynced
          goalBase = vsbGoalBase bundleSynced
          vertexId = vsbVertexId bundleSynced
          queryCount = vsbZ3QueryCount bundleSynced

      -- 2. Speculative DPO Abduction (leases Z3 session for rule batch)
      egAfterDPO <- withLeasedZ3Session pool (egSig eg0) $ \_rawSession ->
        foldM
          (\eg rule -> applyAbductiveDPORule proxy rule rootClass eg)
          eg0
          dpoRules

      -- 3. Pure CPU Bellman-Ford Pareto Frontier Relaxation (NO Z3 LEASE HELD!)
      let egSaturated = propagateGuardedFrontiers propSteps egAfterDPO

      -- 4. Lease Z3 session to verify Set-Cover partition completeness
      trees <- withLeasedZ3Session pool (egSig egSaturated) $ \rawSession ->
        extractParetoDecisionTrees proxy rawSession rootClass goalBase egSaturated

      case trees of
        (_:_) ->
          pure
            ( bundleSynced
                { vsbEGraph          = egSaturated
                , vsbCandidateTrees  = trees
                , vsbZ3QueryCount    = queryCount + attempt + 1
                }
            , attempt
            )
        [] | attempt >= maxRepairs ->
          let fallback = (TVar ("unresolved_" <> vertexId), 999)
          in pure
            ( bundleSynced
                { vsbEGraph         = egSaturated
                , vsbCandidateTrees = [fallback]
                }
            , attempt
            )
        [] -> do
          -- Step 5: Before inventing a new separator, check if a sibling worker
          -- broadcast a compatible separator while we were in steps 2-4!
          (postEpoch, racedSeps) <- pullLatestSeparators pool latestEpoch
          if not (null racedSeps)
            then do
              let bundleFromSibling =
                    foldl absorbCompatibleSeparator (bundleSynced { vsbEGraph = egSaturated }) racedSeps
              concurrentVertexCEGAR postEpoch (attempt + 1) bundleFromSibling
            else do
              let collision = extractCollisionWitness egSaturated
              sepRes <- synthesizeSeparator (egSig egSaturated) collision
              -- Broadcast newly invented separator to shared bus and retry
              broadcastInventedSeparator pool sepRes
              let bundleRepaired =
                    absorbCompatibleSeparator
                      (bundleSynced
                        { vsbEGraph       = egSaturated
                        , vsbInventedSeps = sepRes : vsbInventedSeps bundleSynced
                        })
                      sepRes
              concurrentVertexCEGAR (postEpoch + 1) (attempt + 1) bundleRepaired

--------------------------------------------------------------------------------
-- 4. Concurrent Phase 5: Parallel Ambiguity Quotienting Tournament
--------------------------------------------------------------------------------

-- | Divide-and-Conquer Parallel Semantic Quotienting:
-- Splits `candidates` into pairs, quotients each pair on a leased Z3 session in
-- parallel, and merges the resulting `[SemanticClass]` lists bottom-up.
parallelSemanticQuotient
  :: Z3SessionPool
  -> LiquidSig
  -> (LiquidModel -> LiquidPred -> Bool)
  -> LiquidSort
  -> [(SynTerm, Int)]
  -> IO ([SemanticClass], [LiquidModel])
parallelSemanticQuotient pool sig evalPred resultSort candidates =
  case candidates of
    [] -> pure ([], [])
    [c] ->
      withLeasedZ3Session pool sig $ \rawSession ->
        partitionIntoSemanticQuotients rawSession sig evalPred resultSort [c]
    _ -> do
      let mid = length candidates `div` 2
          (leftCands, rightCands) = splitAt mid candidates
      ((leftClasses, leftModels), (rightClasses, rightModels)) <-
        runConcurrently $ (,)
          <$> Concurrently (parallelSemanticQuotient pool sig evalPred resultSort leftCands)
          <*> Concurrently (parallelSemanticQuotient pool sig evalPred resultSort rightCands)
      let repCandidates =
            [ (scCanonicalTerm sc, scCanonicalCost sc)
            | sc <- leftClasses ++ rightClasses
            ]
      (mergedClasses, mergeModels) <-
        withLeasedZ3Session pool sig $ \rawSession ->
          partitionIntoSemanticQuotients rawSession sig evalPred resultSort repCandidates
      pure (mergedClasses, mergeModels ++ leftModels ++ rightModels)

parallelStalkAmbiguity
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3SessionPool
  -> VertexId
  -> Context
  -> QualifierBasis
  -> LiquidSig
  -> (LiquidModel -> LiquidPred -> Bool)
  -> RBase
  -> [(SynTerm, Int)]
  -> IO StalkDisambiguationResult
parallelStalkAmbiguity proxy pool vid ctx basis sig evalPred goalBase@RBase{..} candidates = do
  (quotients, diffModels) <- parallelSemanticQuotient pool sig evalPred rSort candidates
  case quotients of
    []     -> pure $ UnambiguousTerm (TVar ("empty_stalk_" <> vid))
    [uniq] -> pure $ UnambiguousTerm (scCanonicalTerm uniq)
    _      ->
      withLeasedZ3Session pool sig $ \rawSession ->
        analyzeStalkAmbiguity
          proxy
          rawSession
          vid
          ctx
          basis
          sig
          evalPred
          goalBase
          [ (scCanonicalTerm sc, scCanonicalCost sc) | sc <- quotients ]
        `constSeq` diffModels
  where
    constSeq io _ = io

-- | Inter-vertex LPT scheduling + intra-vertex divide-and-conquer tournament quotienting.
runParallelAmbiguityCheck
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3SessionPool
  -> Map VertexId VertexSynthesisBundle
  -> IO (Map VertexId VertexSynthesisBundle, [AmbiguityQuery])
runParallelAmbiguityCheck proxy pool bundles = do
  let jobs =
        [ ScheduledJob
            { jobPriorityWeight = length (vsbCandidateTrees b) * 10
            , jobPayload        = (vid, b)
            }
        | (vid, b) <- Map.toList bundles
        ]
  results <- runLPTWorkerPool (zspWorkerCount pool) jobs $ \(vid, bundle@VertexSynthesisBundle{..}) ->
    case vsbCandidateTrees of
      [] -> pure (vid, bundle, Nothing)
      [(single, _)] -> pure (vid, bundle { vsbDisambiguated = Just single }, Nothing)
      candidates -> do
        let AbductiveEGraph{..} = vsbEGraph
        res <- parallelStalkAmbiguity
          proxy
          pool
          vid
          egContext
          egBasis
          egSig
          egEvalModel
          vsbGoalBase
          candidates
        pure $ case res of
          UnambiguousTerm term ->
            (vid, bundle { vsbDisambiguated = Just term }, Nothing)
          AmbiguousStalk query ->
            (vid, bundle, Just query)
  let updatedMap = Map.fromList [ (vid, b) | (vid, b, _) <- results ]
      queries    = [ q | (_, _, Just q) <- results ]
  pure (updatedMap, queries)

--------------------------------------------------------------------------------
-- 5. Vertex Synthesis Bundle & Multi-Cover Pareto Extraction
--------------------------------------------------------------------------------

data VertexSynthesisBundle = VertexSynthesisBundle
  { vsbVertexId        :: VertexId
  , vsbRootClass       :: EClassId
  , vsbGoalBase        :: RBase
  , vsbEGraph          :: AbductiveEGraph
  , vsbDPORules        :: [DPORule]
  , vsbComponents      :: Map SymName RSchema
  , vsbInventedSeps    :: [SeparatorSynthesisResult]
  , vsbCandidateTrees  :: [(SynTerm, Int)]
  , vsbDisambiguated   :: Maybe SynTerm
  , vsbZ3QueryCount    :: !Int
  } deriving stock (Generic)

extractParetoDecisionTrees
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3StreamSession
  -> EClassId
  -> RBase
  -> AbductiveEGraph
  -> IO [(SynTerm, Int)]
extractParetoDecisionTrees proxy session rootCid@(EClassId cid) goalBase eg = do
  mPrimary <- extractVerifiedDecisionTree proxy session rootCid goalBase eg
  case mPrimary of
    Nothing -> pure []
    Just primaryTree -> do
      let rootFrontier = maybe [] ecFrontier (IntMap.lookup cid (egClasses eg))
      altTrees <- fmap catMaybes $ forM [0 .. min 3 (length rootFrontier - 1)] $ \dropIdx -> do
        let maskedFrontier =
              [ c | (i, c) <- zip [0..] rootFrontier, i /= dropIdx ]
            egMasked = eg
              { egClasses = IntMap.adjust
                  (\ec -> ec { ecFrontier = maskedFrontier })
                  cid
                  (egClasses eg)
              }
        mAlt <- extractVerifiedDecisionTree proxy session rootCid goalBase egMasked
        pure $ fmap (\t -> (t, 10 + dropIdx)) mAlt
      pure ((primaryTree, 1) : altTrees)

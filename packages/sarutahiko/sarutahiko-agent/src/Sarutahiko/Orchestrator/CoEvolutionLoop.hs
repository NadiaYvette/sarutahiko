{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Sarutahiko.Orchestrator.CoEvolutionLoop
  ( -- * LLM Theory-Level Oracle Interface (Zero Code Tokens)
    LLMTheoryOracle (..)
    -- * Per-Vertex Synthesis Context & Orchestrator State
  , VertexSynthesisBundle (..)
  , CoEvolutionPhase (..)
  , OrchestratorConfig (..)
  , OrchestratorMetrics (..)
  , OrchestratorState (..)
  , CoEvolutionResult (..)
    -- * State-Machine Step & Driver Loop
  , stepCoEvolutionMachine
  , runCoEvolutionLoop
    -- * Multi-Cover Pareto Extraction for Ambiguity Detection
  , extractParetoDecisionTrees
    -- * Pure State-Transformation Helpers
  , isAutoRepairable
  , applyAutoRowRepair
  , injectBankAcrossSheaf
  , lockGlobalSectionsIntoVertices
  , applyTheoryCommand
  , applyResolutionToState
  ) where

import Control.Monad (foldM, forM)
import qualified Data.IntMap.Strict as IntMap
import Data.List (partition)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import GHC.Generics (Generic)

import Gargamelle.CodeGen.Haskell (generateModule)
import Gargamelle.Core.Institution.Liquid
  ( LiquidModel (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSigMorphism (..)
  , LiquidSort (..)
  , MeasureDecl (..)
  , RBase (..)
  , RSchema
  , SymName
  , SynTerm (..)
  )
import Gargamelle.Core.Institution.Liquid.Instance (translatePred)
import Gargamelle.Equational.AbductiveEGraph
  ( AbductiveEGraph (..)
  , DPORule (..)
  , EClassData (..)
  , EClassId (..)
  , Z3StreamSession
  , applyAbductiveDPORule
  , extractVerifiedDecisionTree
  , propagateGuardedFrontiers
  )
import Gargamelle.FOL.GaloisSeparator
  ( GaloisCollision (..)
  , SeparatorSynthesisResult (..)
  , synthesizeSeparator
  )
import Gargamelle.FOL.LiquidHyperdoctrine
  ( FOLFormula (..)
  , Hyperdoctrine (..)
  , LiquidSubHyperdoctrine (..)
  , QualifierBasis (..)
  , QualifierConj (..)
  )
import Gargamelle.Model.AmbiguityOracle
  ( AmbiguityQuery (..)
  , AmbiguityResolution (..)
  , StalkDisambiguationResult (..)
  , analyzeStalkAmbiguity
  , applyAmbiguityResolution
  )
import Gargamelle.Persistence.Crystallize
  ( CrystallizedCombinator (..)
  , PersistentLibraryBank (..)
  , WakeStalkArtifact (..)
  , injectLibraryIntoStalkSig
  , runSleepPhaseCrystallization
  )
import Gargamelle.Sheaf.LatticeCohomology
  ( CohomologyResult (..)
  , EdgeId
  , H1ConflictClassification (..)
  , H1QualifierConflict (..)
  , LiquidCellularSheaf (..)
  , SheafEdgeSpec (..)
  , SheafVertexSpec (..)
  , VertexId
  , solveSheafCohomology
  )
import Gargamelle.Sheaf.LiquidMetaSynthesis
  ( SheafEdgeObstruction (..)
  )
import Sarutahiko.Controller.TheoryDriver
  ( LiquidSymbolicStep (..)
  , TheoryCommand (..)
  , narrowProfunctorPipeline
  )

--------------------------------------------------------------------------------
-- 1. The LLM Theory-Architect Oracle Interface
--------------------------------------------------------------------------------

-- | The LLM interacts with `sarutahiko` exclusively through these callbacks:
-- 1. Resolving irreducible H1 sheaf cohomology conflicts via `TheoryCommand`s.
-- 2. Disambiguating queries on distinguishing input models M_diff.
data LLMTheoryOracle = LLMTheoryOracle
  { llmResolveH1Conflicts :: [H1QualifierConflict] -> IO [TheoryCommand]
  , llmDisambiguateQuery  :: AmbiguityQuery -> IO AmbiguityResolution
  , llmResolveAmbiguities :: [AmbiguityQuery] -> IO [AmbiguityResolution]
  }

--------------------------------------------------------------------------------
-- 2. Vertex Synthesis Bundles & State-Machine Phases
--------------------------------------------------------------------------------

-- | Holds the local AbductiveEGraph, active DPO rewrite laws, goal refinement,
-- and accumulated Galois separator inventions for a single sheaf vertex stalk.
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

data CoEvolutionPhase
  = PhaseWakeLibraryInjection
  | PhaseSheafCohomologyCheck
  | PhaseAwaitLLMH1Repair [H1QualifierConflict]
  | PhaseVertexAbductiveSynthesis (Map EdgeId QualifierConj)
  | PhaseAmbiguityCheck
  | PhaseAwaitLLMAmbiguityPin [AmbiguityQuery]
  | PhaseSleepCrystallizationAndCodeGen
  | PhaseCompleted (Map VertexId Text)
  | PhaseAborted Text
  deriving stock (Show, Generic)

data OrchestratorConfig = OrchestratorConfig
  { cfgMaxTotalIterations    :: !Int
  , cfgMaxGaloisRepairs      :: !Int
  , cfgFrontierPropSteps     :: !Int
  , cfgMdlPromotionThreshold :: !Double
  , cfgTargetModulePrefix    :: Text
  } deriving stock (Show, Generic)

data OrchestratorMetrics = OrchestratorMetrics
  { metTotalIterations     :: !Int
  , metAutoRowRepairs      :: !Int
  , metGaloisMeasuresAdded :: !Int
  , metLLMH1Escalations    :: !Int
  , metLLMAmbiguityQueries :: !Int
  } deriving stock (Eq, Show, Generic)

data OrchestratorState = OrchestratorState
  { ostPhase           :: CoEvolutionPhase
  , ostSheaf           :: LiquidCellularSheaf
  , ostVertices        :: Map VertexId VertexSynthesisBundle
  , ostLibraryBank     :: PersistentLibraryBank
  , ostInternalWitness :: EdgeId -> LiquidPred -> Maybe SheafEdgeObstruction
  , ostMetrics         :: OrchestratorMetrics
  }

data CoEvolutionResult = CoEvolutionResult
  { cerGeneratedModules :: Map VertexId Text
  , cerVerifiedTerms    :: Map VertexId SynTerm
  , cerUpdatedBank      :: PersistentLibraryBank
  , cerFinalMetrics     :: OrchestratorMetrics
  } deriving stock (Show)


--------------------------------------------------------------------------------
-- 3. Top-Level Driver Loop
--------------------------------------------------------------------------------

-- | Runs the `sarutahiko` co-evolutionary state machine until `PhaseCompleted`
-- or `cfgMaxTotalIterations` is reached.
runCoEvolutionLoop
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3StreamSession
  -> OrchestratorConfig
  -> LLMTheoryOracle
  -> OrchestratorState
  -> IO (Either Text CoEvolutionResult)
runCoEvolutionLoop proxy session cfg@OrchestratorConfig{..} oracle = go
  where
    go st =
      case ostPhase st of
        PhaseCompleted mods ->
          let terms = Map.mapMaybe vsbDisambiguated (ostVertices st)
          in pure $ Right CoEvolutionResult
            { cerGeneratedModules = mods
            , cerVerifiedTerms    = terms
            , cerUpdatedBank      = ostLibraryBank st
            , cerFinalMetrics     = ostMetrics st
            }
        PhaseAborted err ->
          pure (Left err)
        _ | metTotalIterations (ostMetrics st) >= cfgMaxTotalIterations ->
          pure (Left "Exceeded cfgMaxTotalIterations in CoEvolutionLoop")
          | otherwise -> do
          stNext <- stepCoEvolutionMachine proxy session cfg oracle st
          let curMetrics = ostMetrics stNext
              stTicked = stNext
                { ostMetrics = curMetrics
                    { metTotalIterations = metTotalIterations curMetrics + 1
                    }
                }
          go stTicked

--------------------------------------------------------------------------------
-- 4. Single-Step State Machine Transition Function
--------------------------------------------------------------------------------

stepCoEvolutionMachine
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3StreamSession
  -> OrchestratorConfig
  -> LLMTheoryOracle
  -> OrchestratorState
  -> IO OrchestratorState
stepCoEvolutionMachine proxy session OrchestratorConfig{..} LLMTheoryOracle{..} st@OrchestratorState{..} =
  case ostPhase of
    ---------------------------------------------------------------------------
    -- PHASE 1: Wake-Phase Library Injection & Profunctor Pipeline Narrowing
    ---------------------------------------------------------------------------
    PhaseWakeLibraryInjection -> do
      let (sheafEnriched, verticesEnriched, profSteps) =
            injectBankAcrossSheaf ostLibraryBank ostSheaf ostVertices
      _narrowedSteps <- narrowProfunctorPipeline
        proxy
        profSteps
        PTrue
        PTrue
      pure st
        { ostPhase    = PhaseSheafCohomologyCheck
        , ostSheaf    = sheafEnriched
        , ostVertices = verticesEnriched
        }

    ---------------------------------------------------------------------------
    -- PHASE 2: Global Sheaf Cohomology (H0 / H1) & Auto-Row Repair
    ---------------------------------------------------------------------------
    PhaseSheafCohomologyCheck -> do
      cohomRes <- solveSheafCohomology proxy ostSheaf ostInternalWitness
      case cohomRes of
        GlobalSectionH0 edgeSections ->
          pure st
            { ostPhase = PhaseVertexAbductiveSynthesis edgeSections
            }
        ObstructionH1 conflicts -> do
          let (autoRepairs, llmEscalations) = partition isAutoRepairable conflicts
          if not (null autoRepairs)
            then do
              let sheafRepaired = foldl applyAutoRowRepair ostSheaf autoRepairs
                  metrics' = ostMetrics
                    { metAutoRowRepairs = metAutoRowRepairs ostMetrics + length autoRepairs
                    }
              pure st
                { ostPhase    = PhaseSheafCohomologyCheck
                , ostSheaf    = sheafRepaired
                , ostMetrics  = metrics'
                }
            else
              pure st
                { ostPhase = PhaseAwaitLLMH1Repair llmEscalations
                }

    ---------------------------------------------------------------------------
    -- PHASE 3: LLM Resolution of Irreducible H1 Architectural Contradictions
    ---------------------------------------------------------------------------
    PhaseAwaitLLMH1Repair irreducibleConflicts -> do
      cmds <- llmResolveH1Conflicts irreducibleConflicts
      let (sheafUpdated, verticesUpdated) =
            foldl applyTheoryCommand (ostSheaf, ostVertices) cmds
          metrics' = ostMetrics
            { metLLMH1Escalations = metLLMH1Escalations ostMetrics + 1
            }
      pure st
        { ostPhase    = PhaseSheafCohomologyCheck
        , ostSheaf    = sheafUpdated
        , ostVertices = verticesUpdated
        , ostMetrics  = metrics'
        }

    ---------------------------------------------------------------------------
    -- PHASE 4: Abductive E-Graph Saturation & Galois Completeness CEGAR
    ---------------------------------------------------------------------------
    PhaseVertexAbductiveSynthesis edgeSections -> do
      let verticesWithEdgeAssumptions =
            lockGlobalSectionsIntoVertices ostSheaf edgeSections ostVertices
      (synthesizedPairs, totalNewMeasures) <- fmap unzip $ forM (Map.toList verticesWithEdgeAssumptions) $ \(vid, bundle) -> do
        (bundle', addedMeas) <- synthesizeVertexWithGaloisCEGAR
          proxy
          session
          cfgMaxGaloisRepairs
          cfgFrontierPropSteps
          bundle
        pure ((vid, bundle'), addedMeas)
      let metrics' = ostMetrics
            { metGaloisMeasuresAdded =
                metGaloisMeasuresAdded ostMetrics + sum totalNewMeasures
            }
      pure st
        { ostPhase    = PhaseAmbiguityCheck
        , ostVertices = Map.fromList synthesizedPairs
        , ostMetrics  = metrics'
        }

    ---------------------------------------------------------------------------
    -- PHASE 5: Semantic Quotienting & Active Ambiguity Detection
    ---------------------------------------------------------------------------
    PhaseAmbiguityCheck -> do
      disambigResults <- forM (Map.toList ostVertices) $ \(vid, bundle@VertexSynthesisBundle{..}) -> do
        let AbductiveEGraph{..} = vsbEGraph
        res <- analyzeStalkAmbiguity
          proxy
          session
          vid
          egContext
          egBasis
          egSig
          egEvalModel
          vsbGoalBase
          vsbCandidateTrees
        pure (vid, bundle, res)
      let ambiguities =
            [ q | (_vid, _b, AmbiguousStalk q) <- disambigResults ]
          updatedVertices = Map.fromList
            [ case res of
                UnambiguousTerm term ->
                  (vid, bundle { vsbDisambiguated = Just term })
                AmbiguousStalk _ ->
                  (vid, bundle)
            | (vid, bundle, res) <- disambigResults
            ]
      if null ambiguities
        then pure st
          { ostPhase    = PhaseSleepCrystallizationAndCodeGen
          , ostVertices = updatedVertices
          }
        else pure st
          { ostPhase    = PhaseAwaitLLMAmbiguityPin ambiguities
          , ostVertices = updatedVertices
          }

    ---------------------------------------------------------------------------
    -- PHASE 6: 1-Bit LLM Ambiguity Resolution & Stalk Morphism Tightening
    ---------------------------------------------------------------------------
    PhaseAwaitLLMAmbiguityPin queries -> do
      resolutions <- mapM llmDisambiguateQuery queries
      let queryMap = Map.fromList [ (aqVertexId q, q) | q <- queries ]
          (sheafTightened, verticesTightened) =
            foldl (applyResolutionToState queryMap) (ostSheaf, ostVertices) resolutions
          metrics' = ostMetrics
            { metLLMAmbiguityQueries =
                metLLMAmbiguityQueries ostMetrics + length resolutions
            }
      pure st
        { ostPhase    = PhaseSheafCohomologyCheck
        , ostSheaf    = sheafTightened
        , ostVertices = verticesTightened
        , ostMetrics  = metrics'
        }

    ---------------------------------------------------------------------------
    -- PHASE 7: Sleep-Phase Library Crystallization & Zero-Cost Code Generation
    ---------------------------------------------------------------------------
    PhaseSleepCrystallizationAndCodeGen -> do
      let wakeArtifacts =
            [ WakeStalkArtifact
                { wsaVertexId          = vsbVertexId
                , wsaInputContext      = egContext vsbEGraph
                , wsaFinalSig          = egSig vsbEGraph
                , wsaDisambiguatedGoal = vsbGoalBase
                , wsaVerifiedTerm      = term
                , wsaInventedSeps      = vsbInventedSeps
                , wsaZ3Refutations     = vsbZ3QueryCount
                }
            | VertexSynthesisBundle{..} <- Map.elems ostVertices
            , Just term <- [vsbDisambiguated]
            ]
      bankUpdated <- runSleepPhaseCrystallization
        proxy
        cfgMdlPromotionThreshold
        wakeArtifacts
        ostLibraryBank
      let generatedMods = Map.fromList
            [ ( vsbVertexId
              , generateModule
                  (cfgTargetModulePrefix <> "." <> vsbVertexId)
                  ("stalk_" <> vsbVertexId)
                  term
              )
            | VertexSynthesisBundle{..} <- Map.elems ostVertices
            , Just term <- [vsbDisambiguated]
            ]
      pure st
        { ostPhase       = PhaseCompleted generatedMods
        , ostLibraryBank = bankUpdated
        }

    PhaseCompleted _ -> pure st
    PhaseAborted _   -> pure st

--------------------------------------------------------------------------------
-- 5. Inner Galois CEGAR Loop & Multi-Cover Pareto Extraction
--------------------------------------------------------------------------------

synthesizeVertexWithGaloisCEGAR
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> Z3StreamSession
  -> Int
  -> Int
  -> VertexSynthesisBundle
  -> IO (VertexSynthesisBundle, Int)
synthesizeVertexWithGaloisCEGAR proxy session maxRepairs propSteps bundle0 =
  cegarLoop 0 bundle0
  where
    cegarLoop :: Int -> VertexSynthesisBundle -> IO (VertexSynthesisBundle, Int)
    cegarLoop attempt bundle@VertexSynthesisBundle{..} = do
      egAfterDPO <- foldM
        (\eg rule -> applyAbductiveDPORule proxy rule vsbRootClass eg)
        vsbEGraph
        vsbDPORules
      let egSaturated = propagateGuardedFrontiers propSteps egAfterDPO
      trees <- extractParetoDecisionTrees proxy session vsbRootClass vsbGoalBase egSaturated
      case trees of
        (_:_) ->
          pure ( bundle
            { vsbEGraph          = egSaturated
            , vsbCandidateTrees  = trees
            , vsbZ3QueryCount    = vsbZ3QueryCount + attempt + 1
            }
          , attempt
          )
        [] | attempt >= maxRepairs ->
          let fallback = (TVar ("unresolved_" <> vsbVertexId), 999)
          in pure ( bundle
            { vsbEGraph          = egSaturated
            , vsbCandidateTrees  = [fallback]
            }
          , attempt
          )
        [] -> do
          let collision = buildCollisionFromEGraph egSaturated
          sepRes@SeparatorSynthesisResult{..} <- synthesizeSeparator (egSig egSaturated) collision
          let sigExtended = (egSig egSaturated)
                { sigMeasures   = case sepNewMeasure of
                    Nothing -> sigMeasures (egSig egSaturated)
                    Just md -> Map.insert (measureName md) md (sigMeasures (egSig egSaturated))
                , sigCtorAxioms = sepNewAxioms ++ sigCtorAxioms (egSig egSaturated)
                , sigQualifiers = Set.insert sepQualifier (sigQualifiers (egSig egSaturated))
                }
              basisExtended = QualifierBasis
                (Set.insert sepQualifier (qbQualifiers (egBasis egSaturated)))
              egRepaired = egSaturated
                { egSig   = sigExtended
                , egBasis = basisExtended
                }
              bundleRepaired = bundle
                { vsbEGraph        = egRepaired
                , vsbInventedSeps  = sepRes : vsbInventedSeps
                }
          cegarLoop (attempt + 1) bundleRepaired

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

buildCollisionFromEGraph :: AbductiveEGraph -> GaloisCollision
buildCollisionFromEGraph AbductiveEGraph{..} =
  case IntMap.elems egWitnessModels of
    (m1 : m2 : _) -> GaloisCollision m1 m2
    [m1]          -> GaloisCollision m1 m1
    []            ->
      let emptyM = LiquidModel Map.empty Map.empty Map.empty
      in GaloisCollision emptyM emptyM

--------------------------------------------------------------------------------
-- 6. Pure State-Transformation Helpers for Sheaf, Library, and TheoryCommands
--------------------------------------------------------------------------------

isAutoRepairable :: H1QualifierConflict -> Bool
isAutoRepairable H1QualifierConflict{..} = case conflictResolution of
  AutoRowRepairable _ _        -> True
  ArchitecturalContradiction _ -> False

applyAutoRowRepair :: LiquidCellularSheaf -> H1QualifierConflict -> LiquidCellularSheaf
applyAutoRowRepair sheaf H1QualifierConflict{..} =
  case conflictResolution of
    AutoRowRepairable _newLbl edgeMorph ->
      let updateEdge e = e { seEdgeSig = morphTarget edgeMorph }
      in sheaf { sheafEdges = Map.adjust updateEdge conflictEdgeId (sheafEdges sheaf) }
    ArchitecturalContradiction _ -> sheaf

injectBankAcrossSheaf
  :: PersistentLibraryBank
  -> LiquidCellularSheaf
  -> Map VertexId VertexSynthesisBundle
  -> (LiquidCellularSheaf, Map VertexId VertexSynthesisBundle, [LiquidSymbolicStep])
injectBankAcrossSheaf bank sheaf0 bundles0 =
  let updatedBundles = Map.map enrichBundle bundles0
      updatedVertices = Map.mapWithKey syncVertexSig (sheafVertices sheaf0)
      profSteps =
        [ LiquidSymbolicStep
            { stepName          = ccName c
            , stepPreCondition  = PTrue
            , stepPostCondition = PTrue
            , stepStateSort     = SortInt
            , stepFuelBound     = Nothing
            }
        | c <- Map.elems (bankCombinators bank)
        ]
  in (sheaf0 { sheafVertices = updatedVertices }, updatedBundles, profSteps)
  where
    enrichBundle b@VertexSynthesisBundle{..} =
      let (sig', comps', _steps) =
            injectLibraryIntoStalkSig bank (egSig vsbEGraph) vsbComponents
          basis' = QualifierBasis (sigQualifiers sig')
      in b { vsbEGraph    = vsbEGraph { egSig = sig', egBasis = basis' }
           , vsbComponents = comps'
           }

    syncVertexSig vid vSpec =
      case Map.lookup vid bundles0 of
        Nothing -> vSpec
        Just b ->
          let (sig', _, _) = injectLibraryIntoStalkSig bank (egSig (vsbEGraph b)) Map.empty
          in vSpec
            { svSig   = sig'
            , svBasis = QualifierBasis (sigQualifiers sig')
            }

lockGlobalSectionsIntoVertices
  :: LiquidCellularSheaf
  -> Map EdgeId QualifierConj
  -> Map VertexId VertexSynthesisBundle
  -> Map VertexId VertexSynthesisBundle
lockGlobalSectionsIntoVertices LiquidCellularSheaf{..} edgeSections bundles0 =
  foldl lockEdge bundles0 (Map.toList edgeSections)
  where
    lockEdge acc (eid, edgeConj) =
      case Map.lookup eid sheafEdges of
        Nothing -> acc
        Just SheafEdgeSpec{..} ->
          let pulledPreds =
                [ translatePred seRestrictTgt p
                | p <- Set.toList (qcConjuncts edgeConj)
                ]
              updateTarget b@VertexSynthesisBundle{..} =
                let sig0 = egSig vsbEGraph
                    sig1 = sig0 { sigPathCond = pulledPreds ++ sigPathCond sig0 }
                in b { vsbEGraph = vsbEGraph { egSig = sig1 } }
          in Map.adjust updateTarget seTargetVert acc

applyTheoryCommand
  :: (LiquidCellularSheaf, Map VertexId VertexSynthesisBundle)
  -> TheoryCommand
  -> (LiquidCellularSheaf, Map VertexId VertexSynthesisBundle)
applyTheoryCommand (sh, vbs) = \case
  DeclareVertexStalk vSpec ->
    (sh { sheafVertices = Map.insert (svVertexId vSpec) vSpec (sheafVertices sh) }, vbs)
  DeclareComponentEdge eSpec ->
    (sh { sheafEdges = Map.insert (seEdgeId eSpec) eSpec (sheafEdges sh) }, vbs)
  ProposeDPORewriteLaw vid dpoRule ->
    let addRule b = b { vsbDPORules = dpoRule : vsbDPORules b }
    in (sh, Map.adjust addRule vid vbs)
  InjectBoundaryWitness vid witnessMdl ->
    let addModel b@VertexSynthesisBundle{..} =
          let eg0 = vsbEGraph
              nextKey = case IntMap.lookupMax (egWitnessModels eg0) of
                Nothing    -> 0
                Just (k, _) -> k + 1
              eg1 = eg0 { egWitnessModels = IntMap.insert nextKey witnessMdl (egWitnessModels eg0) }
          in b { vsbEGraph = eg1 }
    in (sh, Map.adjust addModel vid vbs)
  StrengthenStalkAxiom vid ax ->
    let addAxV v = v
          { svSig            = (svSig v) { sigPathCond = ax : sigPathCond (svSig v) }
          , svLocalGuarantee = FAnd [FAtom ax, svLocalGuarantee v]
          }
        addAxB b@VertexSynthesisBundle{..} =
          let eg0 = vsbEGraph
              sig' = (egSig eg0) { sigPathCond = ax : sigPathCond (egSig eg0) }
          in b { vsbEGraph = eg0 { egSig = sig' } }
    in ( sh { sheafVertices = Map.adjust addAxV vid (sheafVertices sh) }
       , Map.adjust addAxB vid vbs
       )

applyResolutionToState
  :: Map VertexId AmbiguityQuery
  -> (LiquidCellularSheaf, Map VertexId VertexSynthesisBundle)
  -> AmbiguityResolution
  -> (LiquidCellularSheaf, Map VertexId VertexSynthesisBundle)
applyResolutionToState queryMap (sh, vbs) res@AmbiguityResolution{..} =
  case (Map.lookup arVertexId queryMap, Map.lookup arVertexId vbs) of
    (Just query, Just bundle) ->
      let (newGoal, pinMorph, egUpdated) =
            applyAmbiguityResolution query res (vsbEGraph bundle)
          bundle' = bundle
            { vsbGoalBase     = newGoal
            , vsbEGraph        = egUpdated
            , vsbDisambiguated = Nothing
            }
          updateV v = v
            { svSig            = morphTarget pinMorph
            , svLocalGuarantee = FAnd [FAtom (rRefine newGoal), svLocalGuarantee v]
            }
      in ( sh { sheafVertices = Map.adjust updateV arVertexId (sheafVertices sh) }
         , Map.insert arVertexId bundle' vbs
         )
    _ -> (sh, vbs)

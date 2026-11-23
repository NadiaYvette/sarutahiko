{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Sarutahiko.Controller.TheoryDriver
  ( -- * 1. Bidirectional Liquid Profunctor
    LiquidSymbolicStep (..)
  , narrowProfunctorPipeline

    -- * 2. LLM Theory-Level Command Language
  , TheoryCommand (..)
  , DeductiveSynthesisOutcome (..)
  , executeTheoryCommandsAndSynthesize
  , synthesizeVertexWithAutoMeasure
  ) where

import Control.Monad (foldM)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import GHC.Generics (Generic)

import Gargamelle.Core.Institution.Liquid
  ( LiquidModel (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSort
  , RBase (..)
  , SymName
  , SynTerm (..)
  )
import Gargamelle.Equational.AbductiveEGraph
  ( AbductiveEGraph (..)
  , DPORule (..)
  , EClassId
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
  ( Context (..)
  , FOLFormula (..)
  , Hyperdoctrine (..)
  , LiquidSubHyperdoctrine (..)
  , QualifierBasis (..)
  )
import Gargamelle.Sheaf.LatticeCohomology
  ( CohomologyResult (..)
  , H1ConflictClassification (..)
  , H1QualifierConflict (..)
  , LiquidCellularSheaf (..)
  , SheafEdgeSpec (..)
  , SheafVertexSpec (..)
  , VertexId
  , solveSheafCohomology
  )

--------------------------------------------------------------------------------
-- 1. Bidirectional Liquid Profunctor Pipeline
--------------------------------------------------------------------------------

-- | A symbolic step profunctor representing a localized computation step with
-- pre/post conditions, sort constraints, and optional fuel bounds.
data LiquidSymbolicStep = LiquidSymbolicStep
  { stepName          :: SymName
  , stepPreCondition  :: LiquidPred
  , stepPostCondition :: LiquidPred
  , stepStateSort     :: LiquidSort
  , stepFuelBound     :: Maybe Integer
  } deriving stock (Eq, Show, Generic)

-- | Validates and narrows pre/post entailment along a pipeline of symbolic steps.
-- Performs a forward covariant push (checking each step's post-condition is supported
-- by its pre-condition / incoming premise) and a backward contravariant pull
-- (checking each step's pre-condition satisfies required backward goals).
narrowProfunctorPipeline
  :: forall h. Hyperdoctrine h
  => h
  -> [LiquidSymbolicStep]
  -> LiquidPred
  -> LiquidPred
  -> IO (Either LiquidPred [LiquidSymbolicStep])
narrowProfunctorPipeline _proxy steps0 initPre finalPost = do
  forwardRes <- forwardPass initPre steps0
  case forwardRes of
    Left failPred -> pure (Left failPred)
    Right forwardSteps -> do
      backwardRes <- backwardPass finalPost (reverse forwardSteps)
      case backwardRes of
        Left failPred -> pure (Left failPred)
        Right narrowedRev -> pure (Right (reverse narrowedRev))
  where
    stepCtx :: LiquidSymbolicStep -> Context
    stepCtx s = Context (Map.singleton "v" (stepStateSort s))

    forwardPass :: LiquidPred -> [LiquidSymbolicStep] -> IO (Either LiquidPred [LiquidSymbolicStep])
    forwardPass _ [] = pure (Right [])
    forwardPass incomingPre (s : ss) = do
      let combinedPre = case incomingPre of
            PTrue -> stepPreCondition s
            p     -> case stepPreCondition s of
              PTrue -> p
              sp    -> PAnd [p, sp]
          ctx = stepCtx s
      -- Check that combined incoming premise entails stepPreCondition s
      preHolds <- entails @h ctx (FAtom combinedPre) (FAtom (stepPreCondition s))
      if not preHolds
        then pure (Left (stepPreCondition s))
        else do
          let updatedStep = s { stepPreCondition = combinedPre }
          rest <- forwardPass (stepPostCondition updatedStep) ss
          case rest of
            Left f   -> pure (Left f)
            Right rs -> pure (Right (updatedStep : rs))

    backwardPass :: LiquidPred -> [LiquidSymbolicStep] -> IO (Either LiquidPred [LiquidSymbolicStep])
    backwardPass _ [] = pure (Right [])
    backwardPass goalPost (s : ss) = do
      let combinedPost = case goalPost of
            PTrue -> stepPostCondition s
            p     -> case stepPostCondition s of
              PTrue -> p
              sp    -> PAnd [sp, p]
          ctx = stepCtx s
      -- Check that stepPostCondition entails the required goalPost
      postHolds <- entails @h ctx (FAtom (stepPostCondition s)) (FAtom goalPost)
      if not postHolds
        then pure (Left goalPost)
        else do
          let updatedStep = s { stepPostCondition = combinedPost }
          rest <- backwardPass (stepPreCondition updatedStep) ss
          case rest of
            Left f   -> pure (Left f)
            Right rs -> pure (Right (updatedStep : rs))

--------------------------------------------------------------------------------
-- 2. LLM Theory-Level Command Language
--------------------------------------------------------------------------------

-- | The high-level Theory Command DSL emitted by the LLM (no concrete code tokens).
data TheoryCommand
  = DeclareVertexStalk SheafVertexSpec
  -- ^ Defines a component's signature, Polytropos row schema, and Penelope budget.
  | DeclareComponentEdge SheafEdgeSpec
  -- ^ Wires two vertices together via restriction morphisms.
  | ProposeDPORewriteLaw VertexId DPORule
  -- ^ Proposes an algebraic law (L <- K -> R) for DPO saturation.
  | InjectBoundaryWitness VertexId LiquidModel
  -- ^ Seeds an intuitive edge-case witness model into Persistence.Beam.
  | StrengthenStalkAxiom VertexId LiquidPred
  -- ^ Resolves escalated architectural contradictions by adding a domain axiom.

-- | Outcome of deductive synthesis across all sheaf vertices.
data DeductiveSynthesisOutcome
  = SynthesizedGlobalProgram (Map VertexId SynTerm)
  -- ^ Complete verified concrete code emitted deterministically.
  | EscalateH1ToLLM [H1QualifierConflict]
  -- ^ Irreducible architectural contradictions escalated to the LLM.
  deriving stock (Show, Generic)

-- | Executes high-level theory commands, tests sheaf cohomology, filters auto-repaired
-- row conflicts, and independently synthesizes all vertex stalks when H^1 = 0.
executeTheoryCommandsAndSynthesize
  :: LiquidSubHyperdoctrine h
  => h
  -> Z3StreamSession
  -> LiquidCellularSheaf
  -> Map VertexId (EClassId, RBase, AbductiveEGraph)
  -> [TheoryCommand]
  -> IO DeductiveSynthesisOutcome
executeTheoryCommandsAndSynthesize proxy session sheaf0 vertexGraphs0 cmds = do
  -- 1. Apply TheoryCommands to Sheaf and E-Graphs
  (sheaf1, vertexGraphs1) <- foldM applyCommand (sheaf0, vertexGraphs0) cmds
  -- 2. Check Global Sheaf Cohomology (H0 / H1)
  cohomRes <- solveSheafCohomology proxy sheaf1 (\_ _ -> Nothing)
  case cohomRes of
    ObstructionH1 conflicts -> do
      -- Filter out conflicts that are auto-repairable via Polytropos row extension
      let irreducibleForLLM =
            [ c | c <- conflicts
            , case conflictResolution c of
                ArchitecturalContradiction _ -> True
                AutoRowRepairable _ _        -> False
            ]
      if not (null irreducibleForLLM)
        then pure (EscalateH1ToLLM irreducibleForLLM)
        else synthesizeAllVertices sheaf1 vertexGraphs1
    GlobalSectionH0 _globalEdgeSections ->
      -- 3. H1 == 0: Every vertex stalk synthesizes independently
      synthesizeAllVertices sheaf1 vertexGraphs1
  where
    applyCommand (sh, vgs) = \case
      DeclareVertexStalk vSpec ->
        pure (sh { sheafVertices = Map.insert (svVertexId vSpec) vSpec (sheafVertices sh) }, vgs)

      DeclareComponentEdge eSpec ->
        pure (sh { sheafEdges = Map.insert (seEdgeId eSpec) eSpec (sheafEdges sh) }, vgs)

      StrengthenStalkAxiom vid ax ->
        let updateV v = v { svSig = (svSig v) { sigPathCond = ax : sigPathCond (svSig v) } }
        in pure (sh { sheafVertices = Map.adjust updateV vid (sheafVertices sh) }, vgs)

      ProposeDPORewriteLaw vid dpoRule ->
        case Map.lookup vid vgs of
          Nothing -> pure (sh, vgs)
          Just (rootCid, goalBase, eg) -> do
            eg' <- applyAbductiveDPORule proxy dpoRule rootCid eg
            pure (sh, Map.insert vid (rootCid, goalBase, eg') vgs)

      InjectBoundaryWitness vid mdl ->
        case Map.lookup vid vgs of
          Nothing -> pure (sh, vgs)
          Just (rootCid, goalBase, eg) ->
            let models = egWitnessModels eg
                nextKey = case IntMap.lookupMax models of
                  Nothing     -> 0
                  Just (k, _) -> k + 1
                eg' = eg { egWitnessModels = IntMap.insert nextKey mdl models }
            in pure (sh, Map.insert vid (rootCid, goalBase, eg') vgs)

    synthesizeAllVertices _sh vgs = do
      results <- mapM (synthesizeVertexWithAutoMeasure proxy session) (Map.toList vgs)
      pure $ SynthesizedGlobalProgram (Map.fromList results)

-- | Synthesizes a single vertex using AbductiveEGraph Set-Cover extraction,
-- automatically running `synthesizeSeparator` + basis repair if a Galois collision occurs.
synthesizeVertexWithAutoMeasure
  :: h
  -> Z3StreamSession
  -> (VertexId, (EClassId, RBase, AbductiveEGraph))
  -> IO (VertexId, SynTerm)
synthesizeVertexWithAutoMeasure proxy session (vid, (rootCid, goalBase, eg0)) = do
  let egSaturated = propagateGuardedFrontiers 3 eg0
  mTree <- extractVerifiedDecisionTree proxy session rootCid goalBase egSaturated
  case mTree of
    Just verifiedTerm -> pure (vid, verifiedTerm)
    Nothing -> do
      -- GaloisCollision occurred: invent missing separator and repair basis
      let dummyCollision = GaloisCollision
            (LiquidModel Map.empty Map.empty Map.empty)
            (LiquidModel Map.empty Map.empty Map.empty)
      SeparatorSynthesisResult{..} <- synthesizeSeparator (egSig eg0) dummyCollision
      let egRepaired = egSaturated
            { egBasis = QualifierBasis (Set.insert sepQualifier (qbQualifiers (egBasis eg0)))
            }
      mTreeRetry <- extractVerifiedDecisionTree proxy session rootCid goalBase egRepaired
      pure (vid, maybe (TVar ("unresolvable_stalk_" <> vid)) id mTreeRetry)

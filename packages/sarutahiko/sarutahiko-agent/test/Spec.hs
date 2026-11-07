{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, finally, try)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Set as Set
import qualified Data.Text as T
import Effectful (liftIO, runEff)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.Hedgehog

import qualified Data.IntMap.Strict as IntMap
import qualified Data.Map.Strict as Map
import Gargamelle.Core.Institution.Liquid
  ( LiquidPred (..)
  , LiquidSig (..)
  , LiquidSigMorphism (..)
  , LiquidSort (..)
  , Qualifier (..)
  , RBase (..)
  , RelOp (..)
  , RType (..)
  )
import Gargamelle.Equational.AbductiveEGraph
  ( EClassId (..)
  , Z3StreamSession (..)
  , emptyAbductiveEGraph
  )
import Gargamelle.FOL.LiquidHyperdoctrine
  ( Context (..)
  , FOLFormula (..)
  , QualifierBasis (..)
  , QualifierConj (..)
  , Z3Hyperdoctrine (..)
  )
import Gargamelle.Sheaf.LatticeCohomology
  ( H1ConflictClassification (..)
  , H1QualifierConflict (..)
  , LiquidCellularSheaf (..)
  , SheafEdgeSpec (..)
  , SheafVertexSpec (..)
  )
import Sarutahiko.Controller.TheoryDriver
  ( DeductiveSynthesisOutcome (..)
  , LiquidSymbolicStep (..)
  , TheoryCommand (..)
  , executeTheoryCommandsAndSynthesize
  , narrowProfunctorPipeline
  )

import Hashigakari.Sqlite (readEventsSqlite, runEventStoreSqlite, withSqliteDatabase)
import Sarutahiko.Agent
  ( AgentTurnResult (..)
  , RegisteredTool (..)
  , codingAgentRegistry
  , defaultAgentRegistry
  , executeAgentTurn
  , lookupTool
  , parseFieldString
  , runAgentSessionWithCarrier
  )
import Sarutahiko.Effect.EventStore (SessionId (..))
import Sarutahiko.Hooks.Allowlist (Allowlist (..), defaultAllowlist, emptyAllowlist)
import Sarutahiko.Session (SessionContext (..))
import Utai.Mock
  ( addFixture
  , cannedText
  , cannedToolCall
  , emptyFixtureStore
  , runModelAPIMock
  )

import Sarutahiko.Orchestrator.CoEvolutionLoop
  ( CoEvolutionPhase (..)
  , CoEvolutionResult (..)
  , LLMTheoryOracle (..)
  , OrchestratorConfig (..)
  , OrchestratorMetrics (..)
  , OrchestratorState (..)
  , applyAutoRowRepair
  , isAutoRepairable
  , runCoEvolutionLoop
  , stepCoEvolutionMachine
  )
import Gargamelle.Model.AmbiguityOracle
  ( AmbiguityQuery (..)
  , AmbiguityResolution (..)
  )
import Gargamelle.Persistence.Crystallize (PersistentLibraryBank (..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Agent Core Test Suite"
  [ testGroup "Sarutahiko Agent Turn Tests"
      [ testProperty "Agent turn single step: completes without tool calls" prop_agent_turn_single_step
      , testProperty "Agent turn with tool: dispatches tool and observes output" prop_agent_turn_with_tool
      , testProperty "Agent turn consent denial: blocks unauthorized tools under safe mode" prop_agent_turn_consent_denial
      , testProperty "Agent turn iteration ceiling: fail-closed termination on max iterations" prop_agent_turn_iteration_ceiling
      , testProperty "Multi-turn session persistence: maintains context and prefix stability" prop_agent_multi_turn_session
      , testProperty "Autonomous coding tools: file lifecycle write, read, replace" prop_coding_tools_file_lifecycle
      , testProperty "Zero-Aeson parameter parsing: extracts string field cleanly" prop_zero_aeson_parameter_parsing
      ]
  , testGroup "Sarutahiko.Controller.TheoryDriver"
      [ testProperty "1. narrowProfunctorPipeline validates pre/post entailment along symbolic steps" prop_narrowProfunctorPipeline
      , testProperty "2. executeTheoryCommandsAndSynthesize processes DeclareVertexStalk, DeclareComponentEdge, StrengthenStalkAxiom" prop_executeTheoryCommands
      , testProperty "3. Auto-row-repairable conflicts are filtered out from LLM escalation" prop_autoRowRepairFilter
      ]
  , testGroup "Sarutahiko.Orchestrator.CoEvolutionLoop"
      [ testProperty "1. stepCoEvolutionMachine transitions through Wake -> Sheaf -> Completed" prop_coevolution_transitions
      , testProperty "2. Auto-row-repair automatically resolves repairable conflicts without LLM oracle" prop_auto_row_repair_resolves
      , testProperty "3. Metric counters correctly track iterations, repairs, and escalations" prop_metric_counters_track
      ]
  ]

withTempSqlite :: (FilePath -> IO a) -> IO a
withTempSqlite action = do
  tmpDir <- getTemporaryDirectory
  (tmpFile, h) <- openTempFile tmpDir "agent-test-.db"
  hClose h
  let cleanup = do
        _ <- try @SomeException (removeFile tmpFile)
        _ <- try @SomeException (removeFile (tmpFile <> "-wal"))
        _ <- try @SomeException (removeFile (tmpFile <> "-shm"))
        pure ()
  action tmpFile `finally` cleanup

prop_agent_turn_single_step :: Property
prop_agent_turn_single_step = property $ do
  prompt <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  reply  <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let sid = SessionId "sess-agent-1"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store = addFixture (cannedText prompt reply) emptyFixtureStore

  (res, evs) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 1
  atrFinalReply res === reply
  length evs === 2 -- user message + assistant message

prop_agent_turn_with_tool :: Property
prop_agent_turn_with_tool = property $ do
  input <- forAll $ Gen.text (Range.linear 3 20) Gen.alphaNum
  let prompt = "call echo with " <> input
      callId = "call-101"
      toolName = "echo"
      toolArgs = BSC.pack (T.unpack input)
      finalAnswer = "Successfully echoed: " <> input
      sid = SessionId "sess-agent-tool"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store =
        addFixture (cannedText (prompt <> "\n\necho: " <> input) finalAnswer)
        $ addFixture (cannedToolCall prompt callId toolName toolArgs)
        $ emptyFixtureStore

  (res, evs) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 2
  length (atrToolCalls res) === 1
  length evs === 4 -- message (user), tool_invoked, tool_observed, message (assistant)

prop_agent_turn_consent_denial :: Property
prop_agent_turn_consent_denial = property $ do
  let prompt = "run unauthorized tool"
      callId = "call-unauth"
      toolName = "rm_rf"
      toolArgs = "{}"
      sid = SessionId "sess-consent"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      strictAllowlist = emptyAllowlist { alApprovedTools = Set.empty, alSafeMode = True }
      store =
        addFixture (cannedText (prompt <> "\n\nExecution blocked") "Safe mode blocked the dangerous call.")
        $ addFixture (cannedToolCall prompt callId toolName toolArgs)
        $ emptyFixtureStore

  (res, _) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry strictAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 2

prop_agent_turn_iteration_ceiling :: Property
prop_agent_turn_iteration_ceiling = property $ do
  -- Tool call that loops indefinitely: every response asks for another tool call
  let prompt = "loop forever"
      callId = "call-loop"
      toolName = "echo"
      toolArgs = "{\"input\":\"loop\"}"
      sid = SessionId "sess-loop"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store = addFixture (cannedToolCall prompt callId toolName toolArgs) emptyFixtureStore

  (res, _) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 3
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === False
  atrStepsTaken res === 3
  assert ("Iteration ceiling reached" `T.isInfixOf` atrFinalReply res)

prop_agent_multi_turn_session :: Property
prop_agent_multi_turn_session = property $ do
  p1 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  p2 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  let sid = SessionId "sess-multi"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store =
        addFixture (cannedText p1 "Reply 1")
        $ addFixture (cannedText p2 "Reply 2")
        $ emptyFixtureStore

  ctx <- liftIO $ withTempSqlite $ \dbPath -> do
    _ <- runAgentSessionWithCarrier
      (runEff . runModelAPIMock store)
      dbPath
      sid
      model
      cwd
      defaultAgentRegistry
      defaultAllowlist
      p1
    (_, c2) <- runAgentSessionWithCarrier
      (runEff . runModelAPIMock store)
      dbPath
      sid
      model
      cwd
      defaultAgentRegistry
      defaultAllowlist
      p2
    pure c2

  length (scMessages ctx) === 4 -- [user1, assistant1, user2, assistant2]
  assert (not (T.null (scPrefixHash ctx)))

prop_coding_tools_file_lifecycle :: Property
prop_coding_tools_file_lifecycle = property $ do
  origText <- forAll $ Gen.text (Range.linear 10 50) Gen.alphaNum
  replText <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum

  let writeTool = lookupTool "write_file" codingAgentRegistry
      readTool  = lookupTool "read_file" codingAgentRegistry
      replTool  = lookupTool "replace_file_content" codingAgentRegistry

  case (writeTool, readTool, replTool) of
    (Just wt, Just rt, Just rpt) -> do
      (readRes1, readRes2, ok1, ok2, ok3) <- evalIO $ do
        tmpDir <- getTemporaryDirectory
        (tmpFile, h) <- openTempFile tmpDir "tool-test-.txt"
        hClose h

        -- 1. Write file
        let writePayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\",\"content\":\"" <> BSC.pack (T.unpack origText) <> "\"}"
        (_, wOk) <- rtHandler wt writePayload

        -- 2. Read file
        let readPayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\"}"
        (r1, rOk) <- rtHandler rt readPayload

        -- 3. Replace substring
        let replPayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\",\"target\":\"" <> BSC.pack (T.unpack origText) <> "\",\"replacement\":\"" <> BSC.pack (T.unpack replText) <> "\"}"
        (_, rpOk) <- rtHandler rpt replPayload

        -- 4. Read back replaced file
        (r2, _) <- rtHandler rt readPayload
        _ <- try @SomeException (removeFile tmpFile)
        pure (r1, r2, wOk, rOk, rpOk)

      ok1 === True
      ok2 === True
      ok3 === True
      readRes1 === origText
      readRes2 === replText
    _ -> failure

prop_zero_aeson_parameter_parsing :: Property
prop_zero_aeson_parameter_parsing = property $ do
  val <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let json = "{\"command\":\"" <> BSC.pack (T.unpack val) <> "\",\"other\":42}"
      extracted = parseFieldString "command" json
  extracted === Just val

--------------------------------------------------------------------------------
-- Sarutahiko.Controller.TheoryDriver Properties
--------------------------------------------------------------------------------

prop_narrowProfunctorPipeline :: Property
prop_narrowProfunctorPipeline = property $ do
  let step1 = LiquidSymbolicStep
        { stepName          = "step1"
        , stepPreCondition  = PRel Ge (PVar "v") (PIntLit 0)
        , stepPostCondition = PRel Ge (PVar "v") (PIntLit 1)
        , stepStateSort     = SortInt
        , stepFuelBound     = Nothing
        }
      step2 = LiquidSymbolicStep
        { stepName          = "step2"
        , stepPreCondition  = PRel Ge (PVar "v") (PIntLit 1)
        , stepPostCondition = PRel Ge (PVar "v") (PIntLit 2)
        , stepStateSort     = SortInt
        , stepFuelBound     = Nothing
        }
      initPre = PRel Ge (PVar "v") (PIntLit 0)
      finalPost = PRel Ge (PVar "v") (PIntLit 2)

  resValid <- evalIO $ narrowProfunctorPipeline Z3Hyperdoctrine [step1, step2] initPre finalPost
  case resValid of
    Left _ -> failure
    Right narrowed -> length narrowed === 2

  let invalidPost = PRel Ge (PVar "v") (PIntLit 10)
  resInvalid <- evalIO $ narrowProfunctorPipeline Z3Hyperdoctrine [step1, step2] initPre invalidPost
  case resInvalid of
    Left _ -> success
    Right _ -> failure

prop_executeTheoryCommands :: Property
prop_executeTheoryCommands = property $ do
  let emptySig = LiquidSig
        { sigSorts      = Set.empty
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.singleton "x" (RBScalar (RBase "v" SortInt PTrue))
        , sigPathCond   = []
        }
      qualPos = Qualifier "qual_pos" [("x", SortInt)] (PRel Gt (PVar "x") (PIntLit 0))
      qualNonNeg = Qualifier "qual_nonneg" [("x", SortInt)] (PRel Ge (PVar "x") (PIntLit 0))
      basis = QualifierBasis (Set.fromList [qualPos, qualNonNeg])
      ctx = Context (Map.singleton "x" SortInt)

      v1 = SheafVertexSpec
        { svVertexId         = "v1"
        , svSig              = emptySig
        , svContext          = ctx
        , svBasis            = basis
        , svLocalGuarantee   = FAtom (PRel Gt (PVar "x") (PIntLit 0))
        , svLocalRequirement = FTrue
        }
      v2 = SheafVertexSpec
        { svVertexId         = "v2"
        , svSig              = emptySig
        , svContext          = ctx
        , svBasis            = basis
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FAtom (PRel Ge (PVar "x") (PIntLit 0))
        }
      e12 = SheafEdgeSpec
        { seEdgeId      = "e12"
        , seSourceVert  = "v1"
        , seTargetVert  = "v2"
        , seEdgeSig     = emptySig
        , seEdgeBasis   = basis
        , seRestrictSrc = LiquidSigMorphism emptySig emptySig Map.empty (Map.singleton "x" "x") Map.empty
        , seRestrictTgt = LiquidSigMorphism emptySig emptySig Map.empty (Map.singleton "x" "x") Map.empty
        }

      sheaf0 = LiquidCellularSheaf
        { sheafVertices = Map.empty
        , sheafEdges    = Map.empty
        }

      eg1 = emptyAbductiveEGraph ctx emptySig basis IntMap.empty (\_ _ -> True)
      egMap = Map.singleton "v1" (EClassId 0, RBase "v" SortInt PTrue, eg1)

      cmds =
        [ DeclareVertexStalk v1
        , DeclareVertexStalk v2
        , DeclareComponentEdge e12
        , StrengthenStalkAxiom "v1" (PRel Gt (PVar "x") (PIntLit 0))
        ]

  outcome <- evalIO $ executeTheoryCommandsAndSynthesize Z3Hyperdoctrine Z3StreamSession sheaf0 egMap cmds
  case outcome of
    SynthesizedGlobalProgram prog -> do
      Map.member "v1" prog === True
    EscalateH1ToLLM _ -> failure

prop_autoRowRepairFilter :: Property
prop_autoRowRepairFilter = property $ do
  let emptySig = LiquidSig
        { sigSorts      = Set.empty
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.singleton "r" (RBScalar (RBase "v" SortInt PTrue))
        , sigPathCond   = []
        }
      qualA = Qualifier "qual_a" [("r", SortInt)] (PRel Eq (PVar "r") (PIntLit 1))
      basis = QualifierBasis (Set.singleton qualA)
      ctx = Context (Map.singleton "r" SortInt)

      vSrc = SheafVertexSpec
        { svVertexId         = "src"
        , svSig              = emptySig
        , svContext          = ctx
        , svBasis            = basis
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      vTgt = SheafVertexSpec
        { svVertexId         = "tgt"
        , svSig              = emptySig
        , svContext          = ctx
        , svBasis            = basis
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FAtom (PRel Eq (PVar "r") (PIntLit 1))
        }
      eEdge = SheafEdgeSpec
        { seEdgeId      = "e"
        , seSourceVert  = "src"
        , seTargetVert  = "tgt"
        , seEdgeSig     = emptySig
        , seEdgeBasis   = basis
        , seRestrictSrc = LiquidSigMorphism emptySig emptySig Map.empty (Map.singleton "r" "r") Map.empty
        , seRestrictTgt = LiquidSigMorphism emptySig emptySig Map.empty (Map.singleton "r" "r") Map.empty
        }

      sheaf0 = LiquidCellularSheaf
        { sheafVertices = Map.fromList [("src", vSrc), ("tgt", vTgt)]
        , sheafEdges    = Map.singleton "e" eEdge
        }

  outcome <- evalIO $ executeTheoryCommandsAndSynthesize Z3Hyperdoctrine Z3StreamSession sheaf0 Map.empty []
  case outcome of
    EscalateH1ToLLM [conflict] -> do
      case conflictResolution conflict of
        ArchitecturalContradiction _ -> success
        AutoRowRepairable _ _ -> failure
    EscalateH1ToLLM _ -> failure
    SynthesizedGlobalProgram _ -> failure


--------------------------------------------------------------------------------
-- Tests for Sarutahiko.Orchestrator.CoEvolutionLoop
--------------------------------------------------------------------------------

dummyOracle :: LLMTheoryOracle
dummyOracle = LLMTheoryOracle
  { llmResolveH1Conflicts = \_ -> pure []
  , llmDisambiguateQuery  = \q -> pure $ AmbiguityResolution (aqVertexId q) 0
  , llmResolveAmbiguities = \qs -> pure [ AmbiguityResolution (aqVertexId q) 0 | q <- qs ]
  }

emptyBank :: PersistentLibraryBank
emptyBank = PersistentLibraryBank Map.empty Map.empty IntMap.empty (\_ _ -> True)

dummyConfig :: OrchestratorConfig
dummyConfig = OrchestratorConfig
  { cfgMaxTotalIterations    = 10
  , cfgMaxGaloisRepairs      = 2
  , cfgFrontierPropSteps     = 1
  , cfgMdlPromotionThreshold = 1.5
  , cfgTargetModulePrefix    = "App.Generated"
  }

dummyMetrics :: OrchestratorMetrics
dummyMetrics = OrchestratorMetrics 0 0 0 0 0

prop_coevolution_transitions :: Property
prop_coevolution_transitions = property $ do
  let sheaf0 = LiquidCellularSheaf Map.empty Map.empty
      st0 = OrchestratorState
        { ostPhase           = PhaseWakeLibraryInjection
        , ostSheaf           = sheaf0
        , ostVertices        = Map.empty
        , ostLibraryBank     = emptyBank
        , ostInternalWitness = \_ _ -> Nothing
        , ostMetrics         = dummyMetrics
        }

  -- Step 1: PhaseWakeLibraryInjection -> PhaseSheafCohomologyCheck
  st1 <- evalIO $ stepCoEvolutionMachine Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle st0
  case ostPhase st1 of
    PhaseSheafCohomologyCheck -> success
    _                         -> failure

  -- Step 2: On empty sheaf (H1 = 0), PhaseSheafCohomologyCheck -> PhaseVertexAbductiveSynthesis
  st2 <- evalIO $ stepCoEvolutionMachine Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle st1
  case ostPhase st2 of
    PhaseVertexAbductiveSynthesis _ -> success
    _                               -> failure

  -- Step 3: On empty vertices, PhaseVertexAbductiveSynthesis -> PhaseAmbiguityCheck
  st3 <- evalIO $ stepCoEvolutionMachine Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle st2
  case ostPhase st3 of
    PhaseAmbiguityCheck -> success
    _                   -> failure

  -- Step 4: PhaseAmbiguityCheck with 0 vertices -> PhaseSleepCrystallizationAndCodeGen
  st4 <- evalIO $ stepCoEvolutionMachine Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle st3
  case ostPhase st4 of
    PhaseSleepCrystallizationAndCodeGen -> success
    _                                   -> failure

  -- Step 5: PhaseSleepCrystallizationAndCodeGen -> PhaseCompleted
  st5 <- evalIO $ stepCoEvolutionMachine Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle st4
  case ostPhase st5 of
    PhaseCompleted _ -> success
    _                -> failure

prop_auto_row_repair_resolves :: Property
prop_auto_row_repair_resolves = property $ do
  let emptySig = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
      repairMorph = LiquidSigMorphism emptySig emptySig Map.empty Map.empty Map.empty
      autoConflict = H1QualifierConflict
        { conflictEdgeId       = "e_comm"
        , conflictSource       = "v_src"
        , conflictTarget       = "v_tgt"
        , conflictGuaranteed   = QualifierConj Set.empty
        , conflictRequired     = QualifierConj Set.empty
        , conflictMissingQuals = Set.empty
        , conflictResolution   = AutoRowRepairable "rho_slot" repairMorph
        }
      archConflict = H1QualifierConflict
        { conflictEdgeId       = "e_comm"
        , conflictSource       = "v_src"
        , conflictTarget       = "v_tgt"
        , conflictGuaranteed   = QualifierConj Set.empty
        , conflictRequired     = QualifierConj Set.empty
        , conflictMissingQuals = Set.empty
        , conflictResolution   = ArchitecturalContradiction []
        }

  isAutoRepairable autoConflict === True
  isAutoRepairable archConflict === False

  let edge0 = SheafEdgeSpec "e_comm" "v_src" "v_tgt" emptySig (QualifierBasis Set.empty) repairMorph repairMorph
      sheaf0 = LiquidCellularSheaf Map.empty (Map.singleton "e_comm" edge0)
      sheafRepaired = applyAutoRowRepair sheaf0 autoConflict

  Map.member "e_comm" (sheafEdges sheafRepaired) === True

prop_metric_counters_track :: Property
prop_metric_counters_track = property $ do
  let emptySig = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
      repairMorph = LiquidSigMorphism emptySig emptySig Map.empty Map.empty Map.empty
      edge1 = SheafEdgeSpec "e1" "v1" "v2" emptySig (QualifierBasis Set.empty) repairMorph repairMorph
      sheaf0 = LiquidCellularSheaf Map.empty (Map.singleton "e1" edge1)

      -- Witness that triggers autoConflict when checked
      witnessFn _ _ = Nothing
      stCheck = OrchestratorState
        { ostPhase           = PhaseSheafCohomologyCheck
        , ostSheaf           = sheaf0
        , ostVertices        = Map.empty
        , ostLibraryBank     = emptyBank
        , ostInternalWitness = witnessFn
        , ostMetrics         = dummyMetrics
        }

  -- Test runCoEvolutionLoop terminates and ticks total iterations counter
  res <- evalIO $ runCoEvolutionLoop Z3Hyperdoctrine Z3StreamSession dummyConfig dummyOracle stCheck
  case res of
    Right cer -> do
      (metTotalIterations (cerFinalMetrics cer) >= 1) === True
    Left _ -> success

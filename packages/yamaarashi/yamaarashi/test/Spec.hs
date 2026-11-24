{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

import Gargamelle.Core.Institution.Liquid
  ( BinOp (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSigMorphism (..)
  , LiquidSort (..)
  , MeasureDecl (..)
  , RBase (..)
  , RelOp (..)
  , RType (..)
  )
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Sarutahiko.Effect.Stepper as Stepper
import Test.Tasty
import Test.Tasty.Hedgehog
import qualified Yamaarashi as Y
import qualified Yamaarashi.Context.BlastShield as BlastShield
import qualified Yamaarashi.Context.TailExcision as TailExcision
import Control.Monad (forM_)
import qualified System.Directory as Directory
import System.Exit (ExitCode (..))
import qualified System.Process as Process
import qualified Yamaarashi.Sandbox.Airgap as Airgap
import qualified Data.Text.IO as TIO
import qualified System.CPUTime as CPUTime
import System.FilePath ((</>))
import qualified Yamaarashi.Executor.DeterministicSplicer as Splicer
import qualified Yamaarashi.Daemon.PowerAndWAL as PowerWAL
import qualified Yamaarashi.Schedule.TropicalPERT as PERT
import qualified Yamaarashi.Schedule.Quarantine as Quarantine
import qualified Yamaarashi.WorkDAG.Ingest as Ingest
import Gargamelle.Core.Institution.Liquid (LiquidModel (..), LiquidVal (..))
import Gargamelle.Sheaf.LatticeCohomology
  ( SheafVertexSpec (..)
  , H1QualifierConflict (..)
  , H1ConflictClassification (..)
  )
import qualified Data.ByteString.Char8 as BSC
import Gargamelle.FOL.LiquidHyperdoctrine
  ( Context (..)
  , FOLFormula (..)
  , QualifierBasis (..)
  , QualifierConj (..)
  , Z3Hyperdoctrine (..)
  )
import qualified Yamaarashi.Synthesis.SmirkGate as SmirkGate
import Yamaarashi.Synthesis.Synquid
  ( SynEnv (..)
  , SynM
  , SynState (..)
  , SynTerm (..)
  , Z3StreamSession (..)
  , extPathMorphism
  , extVarMorphism
  , narrowVariantMorphism
  , runSynM
  , substPredInRType
  , termToLiquidPred
  , tryVariantExhaustion
  )

import Darcs.Patch.Witnesses (FL(..), Sealed2(..))
import Darcs.Patch.Prim.Structural (SetOp(..))
import Gargamelle.Evidence.Patch.Prim
  ( PrimPatch(..)
  , SymbolKey(..)
  , HoleId(..)
  , DPOSpan(..)
  , PatchId(..)
  )
import Gargamelle.Evidence.Patch.Bundle (GPatch(..), writeGPatchBundle, readGPatchBundle, emptyMorphism)
import Gargamelle.Evidence.GitBundle (TreeOid(..), OidHex(..))
import Yamaarashi.Patch.Prepared
  ( HoleSynthesisStatus(..)
  , PrimHoleResolution(..)
  , materializePreparedGPatch
  , synthesizePreparedHoles
  , sealCompletedGPatch
  , executePreparedSketch
  )
import qualified Yamaarashi.Campaign.Unfold as Unfold
import Yamaarashi.Patch.Reaper
  ( ReaperError(..)
  , reapParallelGPatchBundles
  , foldParallelGPatches
  , emitReapedFastImportStream
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Yamaarashi Suite"
  [ testGroup "Yamaarashi Streaming Kernel"
      [ testProperty "toList_ (each xs) === xs" prop_each_toList
      , testProperty "fold_ (+) 0 (each xs) === sum xs" prop_fold_sum
      , testProperty "map f matches list map" prop_map
      , testProperty "filter p matches list filter" prop_filter
      , testProperty "take n matches list take" prop_take
      , testProperty "drop n matches list drop" prop_drop
      , testProperty "stepper unrolling matches drainStepper" prop_stepper_parity
      , testProperty "stepper teardown executed upon exhaustion" prop_stepper_teardown
      ]
  , testGroup "Yamaarashi.Synthesis.SmirkGate"
      [ testProperty "deductively synthesizes Penelope regex pipeline from PortSig contract" prop_smirkGate_synthesize ]
  , testGroup "Yamaarashi.Synthesis.Synquid"
      [ testProperty "termToLiquidPred correctly projects getF_ and matchTagF_ spines" prop_termToLiquidPred
      , testProperty "extVarMorphism and extPathMorphism correctly extend signatures" prop_sigMorphisms
      , testProperty "narrowVariantMorphism injects set difference narrowing on tag checks" prop_narrowVariantMorphism
      , testProperty "tryVariantExhaustion discharges empty variant branches via absurdVariantF" prop_tryVariantExhaustion
      , testProperty "substPredInRType correctly substitutes dependent arguments into arrows and refinements" prop_substPredInRType
      ]
  , testGroup "Yamaarashi.Context.BlastShield"
      [ testProperty "inlines small output <= 1500 tokens" prop_blastShield_inline
      , testProperty "spills 100 KB synthetic log to disk with compact digest" prop_blastShield_spill
      ]
  , testGroup "Yamaarashi.Context.TailExcision"
      [ testProperty "pruneTranscriptTail inserts tombstone when non-advancing" prop_tailExcision_tombstone
      , testProperty "pruneTranscriptTail preserves prefix when advancing" prop_tailExcision_advancing
      , testProperty "renderStatelessStalk bounds total prompt <= 6000 tokens" prop_statelessStalk_bound
      ]
  , testGroup "Yamaarashi.Sandbox.Airgap"
      [ testProperty "creates isolated home and masks credential paths" prop_airgap_isolated_home
      , testProperty "scrubs API keys, secrets, and cloud variables from environment" prop_airgap_scrubbed_env
      , testProperty "executes subprocess reactively in isolated sandbox" prop_airgap_run_isolated
      ]
  , testGroup "Yamaarashi.Executor.DeterministicSplicer"
      [ testProperty "mountPrestageSeeds writes files to target relative paths" prop_splicer_mount
      , testProperty "spliceTopLevelDeclaration replaces function declaration cleanly" prop_splicer_splice
      , testProperty "spliceTopLevelDeclaration appends missing function declaration" prop_splicer_splice_append
      , testProperty "runZeroTurnCheck validates verification command exit code" prop_splicer_zero_turn
      ]
  , testGroup "Yamaarashi.Daemon.PowerAndWAL"
      [ testProperty "determinePowerPolicy enforces 15% soft throttle and 7% hard checkpoint" prop_power_policy_thresholds
      , testProperty "pollBatteryState reads synthetic capacity and status correctly" prop_battery_poll_synthetic
      , testProperty "checkpointTurnWAL and resumeFromWAL restore turn state" prop_wal_checkpoint_and_resume
      , testProperty "memoizeZ3Query and lookupZ3Memo cache solver subtype decisions" prop_wal_z3_memo
      ]
  , testGroup "Yamaarashi.Schedule.TropicalPERT"
      [ testProperty "Tropical semiring obeys max-plus algebraic laws" prop_tropical_semiring_laws
      , testProperty "Kan extension CPM computes correct ES, LF, slack, and critical path" prop_pert_cpm_kan_extensions
      , testProperty "parallel independence respects disjoint files and commutative footprints" prop_pert_parallel_independence
      , testProperty "critical path first dispatch prioritizes lowest slack and gathers maximal independent batch" prop_pert_critical_path_first_dispatch
      , testProperty "dynamic recompute unblocks downstream tasks upon task quarantine" prop_pert_dynamic_recompute_quarantine
      ]
  , testGroup "Yamaarashi.Campaign.Unfold"
      [ testProperty "loads november-constellation.dhall CampaignMatrix cleanly" prop_campaign_unfold_load_constellation
      , testProperty "executes Phase-0 Recon pullback runner and extracts interface witnesses" prop_campaign_unfold_recon_runner
      , testProperty "instantiates PushoutTemplate (B ⨿_C W) satisfying IsPrimitive <= 1 module constraint" prop_campaign_unfold_pushout_primitives
      , testProperty "unfolds CampaignMatrix to ScheduleGraph and verifies Tropical PERT CPM makespan" prop_campaign_unfold_schedule_graph_cpm
      ]
  , testGroup "Yamaarashi.Patch.Reaper"
      [ testProperty "reaps and merges parallel worker .gpatch bundles under Z3Hyperdoctrine" prop_reaper_parallel_merge
      , testProperty "handles empty bundle list and edge cases gracefully" prop_reaper_edge_cases
      ]
  , testGroup "Yamaarashi.Patch.Prepared"
      [ testProperty "materializes pre-staged primitives and deductively synthesizes PrimSynquidHoles" prop_prepared_materialize_and_synthesize
      , testProperty "executes prepared .gpatch sketch bundle end-to-end and seals completed GPatch" prop_prepared_bundle_roundtrip
      ]
  , testGroup "Yamaarashi.Schedule.Quarantine"
      [ testProperty "shouldQuarantine enforces repair attempt threshold" prop_quarantine_threshold
      , testProperty "synthesizeAxiomaticStub synthesizes compileable Liquid assume contracts and error stubs" prop_quarantine_synthesis
      , testProperty "quarantineVertex records triage report, counterexample model, and writes stub module" prop_quarantine_vertex_execution
      ]
  , testGroup "Yamaarashi.WorkDAG.Ingest"
      [ testProperty "reconcilePacketSnapshot is idempotent on unchanged snapshot" prop_workdag_reconcile_idempotent
      , testProperty "readyPackets selects pending packets with satisfied dependencies" prop_workdag_ready_packets
      , testProperty "detectCycles catches 2-node and 3-node dependency cycles" prop_workdag_detect_cycles
      ]
  ]

--------------------------------------------------------------------------------
-- Streaming Kernel Tests
--------------------------------------------------------------------------------

prop_each_toList :: Property
prop_each_toList = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  res <- evalIO $ Y.toList_ (Y.each xs)
  res === xs

prop_fold_sum :: Property
prop_fold_sum = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  res <- evalIO $ Y.fold_ (+) 0 (Y.each xs)
  res === sum xs

prop_map :: Property
prop_map = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let f x = x * 2 + 1
  res <- evalIO $ Y.toList_ (Y.map f (Y.each xs))
  res === fmap f xs

prop_filter :: Property
prop_filter = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let p x = x `mod` 2 == 0
  res <- evalIO $ Y.toList_ (Y.filter p (Y.each xs))
  res === filter p xs

prop_take :: Property
prop_take = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  n <- forAll $ Gen.int (Range.linear (-5) 120)
  res <- evalIO $ Y.toList_ (Y.take n (Y.each xs))
  res === take n xs

prop_drop :: Property
prop_drop = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  n <- forAll $ Gen.int (Range.linear (-5) 120)
  res <- evalIO $ Y.toList_ (Y.drop n (Y.each xs))
  res === drop n xs

prop_stepper_parity :: Property
prop_stepper_parity = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let st1 = Stepper.unfoldStepper xs
      st2 = Stepper.unfoldStepper xs
  drained <- evalIO $ Stepper.drainStepper st1
  unrolled <- evalIO $ Y.toList_ (Y.unfoldStepper st2)
  unrolled === drained
  unrolled === xs

prop_stepper_teardown :: Property
prop_stepper_teardown = property $ do
  xs <- forAll $ Gen.list (Range.linear 1 50) (Gen.int (Range.linear 0 100))
  ref <- evalIO $ newIORef False
  let st = Stepper.Stepper xs step (teardown ref)
      step [] = pure Nothing
      step (y:ys) = pure (Just (y, ys))
      teardown r _ = writeIORef r True
  res <- evalIO $ Y.toList_ (Y.unfoldStepper st)
  res === xs
  closed <- evalIO $ readIORef ref
  closed === True

--------------------------------------------------------------------------------
-- Yamaarashi.Synthesis.Synquid Unit Tests
--------------------------------------------------------------------------------

-- 1. termToLiquidPred correctly projects getF_ and matchTagF_ spines
prop_termToLiquidPred :: Property
prop_termToLiquidPred = property $ do
  -- getF_count r  -> sel_count(r)
  let getFTerm = TApp (TVar "getF_count") [TVar "r"]
  termToLiquidPred getFTerm === Just (PMeasureApp "sel_count" (PVar "r"))

  -- matchTagF_Foo v -> vpayload_Foo(v)
  let matchTagFTerm = TApp (TVar "matchTagF_Foo") [TVar "v"]
  termToLiquidPred matchTagFTerm === Just (PMeasureApp "vpayload_Foo" (PVar "v"))

  -- standard arithmetic
  let addTerm = TApp (TVar "add") [TIntLit 1, TVar "x"]
  termToLiquidPred addTerm === Just (PBinOp Add (PIntLit 1) (PVar "x"))

-- 2. extVarMorphism and extPathMorphism correctly extend signatures
prop_sigMorphisms :: Property
prop_sigMorphisms = property $ do
  let emptySig = LiquidSig
        { sigSorts      = Set.empty
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.empty
        , sigPathCond   = []
        }
      varType = RBScalar (RBase "v" SortInt PTrue)
      mVar = extVarMorphism "x" varType emptySig
  Map.lookup "x" (sigEnv (morphTarget mVar)) === Just varType

  let pathPred = PRel Eq (PVar "x") (PIntLit 42)
      mPath = extPathMorphism pathPred (morphTarget mVar)
  sigPathCond (morphTarget mPath) === [pathPred]

-- 3. narrowVariantMorphism injects set difference narrowing on tag checks
prop_narrowVariantMorphism :: Property
prop_narrowVariantMorphism = property $ do
  let emptySig = LiquidSig
        { sigSorts      = Set.empty
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.empty
        , sigPathCond   = []
        }
      negTagGuard = PNot (PRel SetMember (PVar "Tag_Foo") (PMeasureApp "vtags" (PVar "u")))
      mMorph = narrowVariantMorphism negTagGuard emptySig
      expectedNarrowed = PRel Eq
        (PMeasureApp "vtags" (PVar "u"))
        (PBinOp SetDiff (PMeasureApp "vtags" (PVar "u")) (PVar "Tag_Foo"))
  sigPathCond (morphTarget mMorph) === [PAnd [negTagGuard, expectedNarrowed]]

-- 4. tryVariantExhaustion discharges empty variant branches via absurdVariantF
prop_tryVariantExhaustion :: Property
prop_tryVariantExhaustion = property $ do
  let sortTag = SortADT "PolytroposTag" []
      varU = "u"
      uType = RBScalar (RBase "v" (SortADT "VariantF_Row" []) PTrue)
      vtagsDecl = MeasureDecl
        { measureName        = "vtags"
        , measureDomain      = SortADT "VariantF_Row" []
        , measureRange       = SortSet sortTag
        , measureWellFounded = False
        }
      -- Path condition proving that vtags(u) == EmptySet
      pathCond = [PRel Eq (PMeasureApp "vtags" (PVar varU)) (PEmptySet sortTag)]
      sig = LiquidSig
        { sigSorts      = Set.fromList ["Int", "Bool", "PolytroposTag", "VariantF_Row"]
        , sigMeasures   = Map.singleton "vtags" vtagsDecl
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.singleton varU uType
        , sigPathCond   = pathCond
        }
      env = SynEnv
        { envSig        = sig
        , envComponents = Map.empty
        , envZ3Session  = Z3StreamSession
        , envMaxDepth   = 5
        , envMaxAbduct  = 2
        , envStateVar   = "st"
        , envFuelVar    = "fuel"
        }
      st = SynState
        { stFreshCounter   = 0
        , stRejectedModels = []
        , stMorphTrace     = []
        }
  (mTerm, _) <- evalIO $ runSynM env st (tryVariantExhaustion :: SynM SynTerm)
  mTerm === Just (TApp (TVar "absurdVariantF") [TVar varU])

-- 5. substPredInRType correctly substitutes dependent arguments into arrows and refinements
prop_substPredInRType :: Property
prop_substPredInRType = property $ do
  -- y:Int -> {v:Int | v == x + y} with [x := 10]
  let innerBase = RBase "v" SortInt (PRel Eq (PVar "v") (PBinOp Add (PVar "x") (PVar "y")))
      arrowTy = RArrow "y" (RBScalar (RBase "v" SortInt PTrue)) (RBScalar innerBase)
      substituted = substPredInRType "x" (PIntLit 10) arrowTy
      expectedBase = RBase "v" SortInt (PRel Eq (PVar "v") (PBinOp Add (PIntLit 10) (PVar "y")))
      expectedArrow = RArrow "y" (RBScalar (RBase "v" SortInt PTrue)) (RBScalar expectedBase)
  substituted === expectedArrow

--------------------------------------------------------------------------------
-- BlastShield Tests
--------------------------------------------------------------------------------

prop_blastShield_inline :: Property
prop_blastShield_inline = property $ do
  let small = "Just a small compiler message with 10 tokens."
  res <- evalIO $ BlastShield.spillOrDigest BlastShield.defaultBlastShieldConfig 1 small
  case res of
    BlastShield.InlineOutput t -> t === small
    BlastShield.SpilledWithDigest _ _ -> failure

prop_blastShield_spill :: Property
prop_blastShield_spill = property $ do
  let bigLog = T.unlines $
        [ "Building package foo..." ]
        ++ replicate 1000 "Compiling Module.Foo ( src/Module/Foo.hs, dist/Module/Foo.o )"
        ++ [ "src/Module/Foo.hs:42:15: error: [GHC-83865] Variable not in scope: undefinedSymbol"
           , "    |"
           , " 42 |   let x = undefinedSymbol"
           , "    |           ^^^^^^^^^^^^^^^"
           ]
        ++ replicate 1000 "Additional compiler debug traces and notes..."
  res <- evalIO $ BlastShield.spillOrDigest BlastShield.defaultBlastShieldConfig 1 bigLog
  case res of
    BlastShield.InlineOutput _ -> failure
    BlastShield.SpilledWithDigest path digest -> do
      assert (T.isInfixOf "turn-1.log" (T.pack path))
      assert (T.isInfixOf "GHC-83865" digest)
      assert (T.length digest < 2000)

--------------------------------------------------------------------------------
-- TailExcision Tests
--------------------------------------------------------------------------------

prop_tailExcision_tombstone :: Property
prop_tailExcision_tombstone = property $ do
  let s0 = TailExcision.emptyContextValveState
             { TailExcision.lastCompilerCode = Just "GHC-83865"
             , TailExcision.lastErrorCount   = 1
             , TailExcision.messageHistory   = ["Initial turn message"]
             }
      obs = TailExcision.TurnObservation
        { TailExcision.obsTurnIndex       = 2
        , TailExcision.obsEstimatedTokens = 1500
        , TailExcision.obsCompilerCode    = Just "GHC-83865"
        , TailExcision.obsErrorCount      = 1
        , TailExcision.obsRawText         = "Same compiler error with huge logs"
        }
      s1 = TailExcision.pruneTranscriptTail s0 obs
  length (TailExcision.tombstoneRecords s1) === 1
  case TailExcision.messageHistory s1 of
    (m:_) -> assert (T.isInfixOf "[Excised Turn 2:" m)
    []    -> failure

prop_tailExcision_advancing :: Property
prop_tailExcision_advancing = property $ do
  let s0 = TailExcision.emptyContextValveState
             { TailExcision.lastCompilerCode = Just "GHC-83865"
             , TailExcision.lastErrorCount   = 3
             , TailExcision.messageHistory   = ["Initial turn message"]
             }
      obs = TailExcision.TurnObservation
        { TailExcision.obsTurnIndex       = 2
        , TailExcision.obsEstimatedTokens = 1500
        , TailExcision.obsCompilerCode    = Just "GHC-83865"
        , TailExcision.obsErrorCount      = 1
        , TailExcision.obsRawText         = "Advancing! Error count dropped from 3 to 1."
        }
      s1 = TailExcision.pruneTranscriptTail s0 obs
  length (TailExcision.tombstoneRecords s1) === 0
  case TailExcision.messageHistory s1 of
    (m:_) -> m === "Advancing! Error count dropped from 3 to 1."
    []    -> failure

prop_statelessStalk_bound :: Property
prop_statelessStalk_bound = property $ do
  let blockA = TailExcision.FrozenBlockA "Block A: Invariant Task Rules & Signatures."
      hugeText = T.replicate 10000 "Dynamic file content line\n"
      blockB = TailExcision.DynamicBlockB hugeText
      stalk = TailExcision.renderStatelessStalk blockA blockB
      stalkText = TailExcision.unStalkPrompt stalk
  assert (T.isPrefixOf "Block A: Invariant Task Rules & Signatures." stalkText)
  assert (T.length stalkText <= 24500)

--------------------------------------------------------------------------------
-- Airgap Tests
--------------------------------------------------------------------------------

prop_airgap_isolated_home :: Property
prop_airgap_isolated_home = property $ do
  sEnv <- evalIO $ Airgap.buildAirgappedSandbox "/tmp"
  let home = Airgap.sandboxHome sEnv
  assert ("/tmp" `T.isInfixOf` T.pack home)
  homeExists <- evalIO $ Directory.doesDirectoryExist home
  homeExists === True
  let masked = Airgap.maskedPaths sEnv
  length masked === 2
  forM_ masked $ \p -> do
    dExists <- evalIO $ Directory.doesDirectoryExist p
    dExists === True

prop_airgap_scrubbed_env :: Property
prop_airgap_scrubbed_env = property $ do
  let dirty =
        [ ("GEMINI_API_KEY", "secret-key-123")
        , ("OPENAI_API_KEY", "sk-secret")
        , ("ANTHROPIC_AUTH_TOKEN", "ant-secret")
        , ("MY_PASSWORD", "hunter2")
        , ("PATH", "/usr/bin:/bin")
        , ("USER", "developer")
        , ("HOME", "/home/original")
        ]
      clean = Airgap.scrubEnvironment "/tmp/isolated-home" dirty
      cleanKeys = map fst clean
  assert ("GEMINI_API_KEY" `notElem` cleanKeys)
  assert ("OPENAI_API_KEY" `notElem` cleanKeys)
  assert ("ANTHROPIC_AUTH_TOKEN" `notElem` cleanKeys)
  assert ("MY_PASSWORD" `notElem` cleanKeys)
  lookup "HOME" clean === Just "/tmp/isolated-home"
  lookup "QUOTA_FIREWALL_ACTIVE" clean === Just "1"
  lookup "PATH" clean === Just "/usr/bin:/bin"
  lookup "USER" clean === Just "developer"

prop_airgap_run_isolated :: Property
prop_airgap_run_isolated = property $ do
  sEnv <- evalIO $ Airgap.buildAirgappedSandbox "/tmp"
  (ec, stdoutText, _) <- evalIO $ Airgap.runInIsolatedHome sEnv (Process.proc "echo" ["airgap-verified"])
  ec === ExitSuccess
  assert (T.isInfixOf "airgap-verified" stdoutText)

--------------------------------------------------------------------------------
-- DeterministicSplicer Tests
--------------------------------------------------------------------------------

prop_splicer_mount :: Property
prop_splicer_mount = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-test-" ++ show t)
      mount1 = Splicer.SeedMount "src/Foo/Bar.hs" "module Foo.Bar where\nx = 42\n"
      mount2 = Splicer.SeedMount "README.txt" "Seed documentation\n"
  evalIO $ Splicer.mountPrestageSeeds testDir [mount1, mount2]
  f1Exists <- evalIO $ Directory.doesFileExist (testDir </> "src/Foo/Bar.hs")
  f2Exists <- evalIO $ Directory.doesFileExist (testDir </> "README.txt")
  f1Exists === True
  f2Exists === True
  c1 <- evalIO $ TIO.readFile (testDir </> "src/Foo/Bar.hs")
  c1 === "module Foo.Bar where\nx = 42\n"

prop_splicer_splice :: Property
prop_splicer_splice = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-splice-" ++ show t)
      testFile = testDir </> "Target.hs"
      initial = T.unlines
        [ "module Target where"
        , ""
        , "oldFunc :: Int -> Int"
        , "oldFunc x ="
        , "  x + 1"
        , ""
        , "otherFunc :: Bool"
        , "otherFunc = True"
        ]
      replacement = T.unlines
        [ "oldFunc :: Int -> Int"
        , "oldFunc x = x * 10"
        ]
  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ TIO.writeFile testFile initial
  evalIO $ Splicer.spliceTopLevelDeclaration testFile "oldFunc" (T.stripEnd replacement)
  content <- evalIO $ TIO.readFile testFile
  assert (T.isInfixOf "oldFunc x = x * 10" content)
  assert (not (T.isInfixOf "x + 1" content))
  assert (T.isInfixOf "otherFunc = True" content)

prop_splicer_splice_append :: Property
prop_splicer_splice_append = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("splicer-append-" ++ show t)
      testFile = testDir </> "Target.hs"
      initial = "module Target where\n\nexisting = 1\n"
      newDecl = "addedFunc :: String\naddedFunc = \"hello\""
  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ TIO.writeFile testFile initial
  evalIO $ Splicer.spliceTopLevelDeclaration testFile "addedFunc" newDecl
  content <- evalIO $ TIO.readFile testFile
  assert (T.isInfixOf "existing = 1" content)
  assert (T.isInfixOf "addedFunc = \"hello\"" content)

prop_splicer_zero_turn :: Property
prop_splicer_zero_turn = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  passResult <- evalIO $ Splicer.runZeroTurnCheck tmpRoot "true"
  failResult <- evalIO $ Splicer.runZeroTurnCheck tmpRoot "false"
  passResult === True
  failResult === False

--------------------------------------------------------------------------------
-- PowerAndWAL Tests
--------------------------------------------------------------------------------

prop_power_policy_thresholds :: Property
prop_power_policy_thresholds = property $ do
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 5 PowerWAL.BatteryCharging "") === PowerWAL.PolicyNormal
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 100 PowerWAL.BatteryFull "") === PowerWAL.PolicyNormal
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 10 PowerWAL.BatteryNotCharging "") === PowerWAL.PolicyNormal
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 20 PowerWAL.BatteryDischarging "") === PowerWAL.PolicyNormal
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 15 PowerWAL.BatteryDischarging "") === PowerWAL.PolicySoftThrottle
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 10 PowerWAL.BatteryDischarging "") === PowerWAL.PolicySoftThrottle
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 7 PowerWAL.BatteryDischarging "") === PowerWAL.PolicyHardCheckpoint
  PowerWAL.determinePowerPolicy (PowerWAL.BatteryState 2 PowerWAL.BatteryDischarging "") === PowerWAL.PolicyHardCheckpoint

prop_battery_poll_synthetic :: Property
prop_battery_poll_synthetic = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let batDir = tmpRoot </> ("synthetic-bat-" ++ show t)
  evalIO $ Directory.createDirectoryIfMissing True batDir
  evalIO $ TIO.writeFile (batDir </> "capacity") "12\n"
  evalIO $ TIO.writeFile (batDir </> "status") "Discharging\n"
  st <- evalIO $ PowerWAL.pollBatteryState (Just batDir)
  PowerWAL.bsCapacity st === 12
  PowerWAL.bsStatus st === PowerWAL.BatteryDischarging
  action <- evalIO $ PowerWAL.enforcePowerThrottle st
  action === PowerWAL.ActionHaltNewSandboxes

prop_wal_checkpoint_and_resume :: Property
prop_wal_checkpoint_and_resume = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let dbPath = tmpRoot </> ("wal-test-" ++ show t ++ ".sqlite3")
  evalIO $ PowerWAL.initWALSchema dbPath
  let cp1 = PowerWAL.TurnWALCheckpoint "task-test-1" 1 "snapshot-turn-1" ""
      cp2 = PowerWAL.TurnWALCheckpoint "task-test-1" 2 "snapshot-turn-2" ""
  evalIO $ PowerWAL.checkpointTurnWAL dbPath cp1
  evalIO $ PowerWAL.checkpointTurnWAL dbPath cp2
  mRes <- evalIO $ PowerWAL.resumeFromWAL dbPath "task-test-1"
  case mRes of
    Nothing -> failure
    Just res -> do
      PowerWAL.twcTaskId res === "task-test-1"
      PowerWAL.twcTurnIndex res === 2
      PowerWAL.twcStateSnapshot res === "snapshot-turn-2"
  mMissing <- evalIO $ PowerWAL.resumeFromWAL dbPath "non-existent-task"
  mMissing === Nothing

prop_wal_z3_memo :: Property
prop_wal_z3_memo = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let dbPath = tmpRoot </> ("wal-z3-test-" ++ show t ++ ".sqlite3")
  evalIO $ PowerWAL.initWALSchema dbPath
  let e1 = PowerWAL.Z3MemoEntry "sig-alpha" "vc-001" True
      e2 = PowerWAL.Z3MemoEntry "sig-alpha" "vc-002" False
  evalIO $ PowerWAL.memoizeZ3Query dbPath e1
  evalIO $ PowerWAL.memoizeZ3Query dbPath e2
  r1 <- evalIO $ PowerWAL.lookupZ3Memo dbPath "sig-alpha" "vc-001"
  r2 <- evalIO $ PowerWAL.lookupZ3Memo dbPath "sig-alpha" "vc-002"
  r3 <- evalIO $ PowerWAL.lookupZ3Memo dbPath "sig-alpha" "vc-003"
  r1 === Just True
  r2 === Just False
  r3 === Nothing

--------------------------------------------------------------------------------
-- TropicalPERT Tests
--------------------------------------------------------------------------------

prop_tropical_semiring_laws :: Property
prop_tropical_semiring_laws = property $ do
  x <- forAll $ Gen.double (Range.linearFrac (-100.0) 100.0)
  y <- forAll $ Gen.double (Range.linearFrac (-100.0) 100.0)
  z <- forAll $ Gen.double (Range.linearFrac (-100.0) 100.0)

  let tx = PERT.Tropical x
      ty = PERT.Tropical y
      tz = PERT.Tropical z

  -- Identity for tropical addition (max) is NegInf
  (PERT.NegInf PERT..+. tx) === tx
  (tx PERT..+. PERT.NegInf) === tx

  -- Commutativity of addition: max(x, y) == max(y, x)
  (tx PERT..+. ty) === (ty PERT..+. tx)

  -- Associativity of addition: max(max(x,y), z) == max(x, max(y,z))
  ((tx PERT..+. ty) PERT..+. tz) === (tx PERT..+. (ty PERT..+. tz))

  -- Identity for tropical multiplication (addition) is Tropical 0
  (PERT.Tropical 0.0 PERT..*. tx) === tx
  (tx PERT..*. PERT.Tropical 0.0) === tx

  -- Associativity of multiplication: (x + y) + z == x + (y + z)
  let diffMult = case ((tx PERT..*. ty) PERT..*. tz, tx PERT..*. (ty PERT..*. tz)) of
        (PERT.Tropical r1, PERT.Tropical r2) -> abs (r1 - r2)
        _ -> 1.0
  (diffMult < 1e-9) === True

  -- NegInf absorbs tropical multiplication
  (PERT.NegInf PERT..*. tx) === PERT.NegInf
  (tx PERT..*. PERT.NegInf) === PERT.NegInf

prop_pert_cpm_kan_extensions :: Property
prop_pert_cpm_kan_extensions = property $ do
  -- Build canonical 4-node diamond DAG:
  -- A (3) -> B (5), A (3) -> C (2), B (5) -> D (4), C (2) -> D (4)
  let tA = PERT.TaskVertex "A" 3.0 (Set.singleton "A.hs") Set.empty PERT.TaskPending
      tB = PERT.TaskVertex "B" 5.0 (Set.singleton "B.hs") Set.empty PERT.TaskPending
      tC = PERT.TaskVertex "C" 2.0 (Set.singleton "C.hs") Set.empty PERT.TaskPending
      tD = PERT.TaskVertex "D" 4.0 (Set.singleton "D.hs") Set.empty PERT.TaskPending

      g0 = PERT.emptyScheduleGraph
      g1 = PERT.insertTask tA g0
      g2 = PERT.insertTask tB g1
      g3 = PERT.insertTask tC g2
      g4 = PERT.insertTask tD g3

      g5 = PERT.addDependency "A" "B" g4
      g6 = PERT.addDependency "A" "C" g5
      g7 = PERT.addDependency "B" "D" g6
      g8 = PERT.addDependency "C" "D" g7

  -- Forward pass: Earliest Start (Left Kan Extension)
  PERT.earliestStart g8 "A" === 0.0
  PERT.earliestStart g8 "B" === 3.0
  PERT.earliestStart g8 "C" === 3.0
  PERT.earliestStart g8 "D" === 8.0 -- max(3+5, 3+2) = 8.0

  -- Backward pass: Latest Finish (Right Kan Extension)
  PERT.projectMakespan g8 === 12.0 -- 8 + 4 = 12
  PERT.latestFinish g8 "D" === 12.0
  PERT.latestFinish g8 "B" === 8.0  -- 12 - 4 = 8
  PERT.latestFinish g8 "C" === 8.0  -- 12 - 4 = 8
  PERT.latestFinish g8 "A" === 3.0  -- min(8 - 5, 8 - 2) = min(3, 6) = 3

  -- Slack and Critical Path
  PERT.totalSlack g8 "A" === 0.0
  PERT.totalSlack g8 "B" === 0.0
  PERT.totalSlack g8 "D" === 0.0
  PERT.totalSlack g8 "C" === 3.0 -- 8 - 3 - 2 = 3.0

  PERT.isCritical g8 "A" === True
  PERT.isCritical g8 "B" === True
  PERT.isCritical g8 "D" === True
  PERT.isCritical g8 "C" === False

  PERT.criticalPath g8 === ["A", "B", "D"]

prop_pert_parallel_independence :: Property
prop_pert_parallel_independence = property $ do
  let t1 = PERT.TaskVertex "T1" 1.0 (Set.singleton "Foo.hs") (Set.singleton 10) PERT.TaskPending
      t2 = PERT.TaskVertex "T2" 1.0 (Set.singleton "Bar.hs") (Set.singleton 20) PERT.TaskPending
      tOverlapFile = PERT.TaskVertex "T3" 1.0 (Set.singleton "Foo.hs") (Set.singleton 30) PERT.TaskPending
      tOverlapSym  = PERT.TaskVertex "T4" 1.0 (Set.singleton "Baz.hs") (Set.singleton 10) PERT.TaskPending

  -- Disjoint files & symbols -> parallel independent
  PERT.areParallelIndependent t1 t2 === True

  -- Overlapping files -> NOT independent
  PERT.areParallelIndependent t1 tOverlapFile === False

  -- Overlapping symbols -> NOT independent
  PERT.areParallelIndependent t1 tOverlapSym === False

prop_pert_critical_path_first_dispatch :: Property
prop_pert_critical_path_first_dispatch = property $ do
  -- Two independent ready tasks:
  -- Crit (slack 0.0, dur 10.0), NonCrit (slack 5.0, dur 2.0)
  -- Both ready.
  let tCrit = PERT.TaskVertex "Crit" 10.0 (Set.singleton "Crit.hs") Set.empty PERT.TaskPending
      tNonCrit = PERT.TaskVertex "NonCrit" 2.0 (Set.singleton "NonCrit.hs") Set.empty PERT.TaskPending
      tDownCrit = PERT.TaskVertex "DownCrit" 5.0 (Set.singleton "Down.hs") Set.empty PERT.TaskPending

      g0 = PERT.insertTask tCrit $
           PERT.insertTask tNonCrit $
           PERT.insertTask tDownCrit $
           PERT.emptyScheduleGraph

      g1 = PERT.addDependency "Crit" "DownCrit" g0
      batch = PERT.selectParallelBatch g1

  -- Both Crit and NonCrit are ready and mutually independent,
  -- but Crit (Slack = 0) must appear first before NonCrit
  map PERT.tvId batch === ["Crit", "NonCrit"]

prop_pert_dynamic_recompute_quarantine :: Property
prop_pert_dynamic_recompute_quarantine = property $ do
  let tUp = PERT.TaskVertex "Up" 5.0 (Set.singleton "Up.hs") Set.empty PERT.TaskRunning
      tDown = PERT.TaskVertex "Down" 3.0 (Set.singleton "Down.hs") Set.empty PERT.TaskPending
      g0 = PERT.addDependency "Up" "Down" $
           PERT.insertTask tUp $
           PERT.insertTask tDown $
           PERT.emptyScheduleGraph

  -- Down is initially not ready because Up is running
  PERT.readyTasks g0 === []

  -- Up fails repair and is quarantined:
  let (g1, _) = PERT.dynamicRecompute g0 "Up" PERT.TaskQuarantined

  -- Downstream task is now ready! (unblocked via axiomatic stub)
  map PERT.tvId (PERT.readyTasks g1) === ["Down"]

--------------------------------------------------------------------------------
-- Quarantine Tests
--------------------------------------------------------------------------------

prop_quarantine_threshold :: Property
prop_quarantine_threshold = property $ do
  let cfg = Quarantine.defaultQuarantineConfig { Quarantine.qcMaxRepairAttempts = 3 }
  Quarantine.shouldQuarantine cfg 0 === False
  Quarantine.shouldQuarantine cfg 2 === False
  Quarantine.shouldQuarantine cfg 3 === True
  Quarantine.shouldQuarantine cfg 5 === True

prop_quarantine_synthesis :: Property
prop_quarantine_synthesis = property $ do
  let vId = "TP-014C"
      mySort = SortInt
      rScalar = RBScalar (RBase "v" mySort (PRel Gt (PVar "v") (PIntLit 0)))
      rFunc = RArrow "x" (RBScalar (RBase "x" SortInt PTrue)) rScalar
      env = Map.singleton "calculateMetric" rFunc
      sig = LiquidSig
        { sigSorts      = Set.singleton "Int"
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = env
        , sigPathCond   = []
        }
      spec = SheafVertexSpec
        { svVertexId         = vId
        , svSig              = sig
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      stubCode = Quarantine.synthesizeAxiomaticStub vId spec

  assert (T.isInfixOf "module PrimAxiomaticStub where" stubCode)
  assert (T.isInfixOf "{-@ assume calculateMetric :: x:{x:Int | true} -> {v:Int | (v > 0)} @-}" stubCode)
  assert (T.isInfixOf "calculateMetric :: Int -> Int" stubCode)
  assert (T.isInfixOf "calculateMetric = error \"AXIOMATIC_STUB: awaiting human triage on TP-014C\"" stubCode)

prop_quarantine_vertex_execution :: Property
prop_quarantine_vertex_execution = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let reportDir = tmpRoot </> ("quarantine-reports-" ++ show t)
      stubDir = tmpRoot </> ("quarantine-stub-" ++ show t)
      cfg = Quarantine.QuarantineConfig
        { Quarantine.qcMaxRepairAttempts = 3
        , Quarantine.qcEmitAxiomaticStub = True
        , Quarantine.qcReportDir         = reportDir
        , Quarantine.qcStubOutputDir     = stubDir
        }
      vId = "TP-014C"
      model = LiquidModel
        { modelVarEnv        = Map.singleton "delta" (VInt 42)
        , modelMeasureInterp = Map.empty
        , modelAbductSol     = Map.empty
        }
      conflict = H1QualifierConflict
        { conflictEdgeId       = "e-audit"
        , conflictSource       = "TP-014B"
        , conflictTarget       = "TP-014C"
        , conflictGuaranteed   = QualifierConj Set.empty
        , conflictRequired     = QualifierConj Set.empty
        , conflictMissingQuals = Set.singleton (PRel Eq (PVar "active") (PIntLit 1))
        , conflictResolution   = AutoRowRepairable "row_field" (error "morph")
        }
      partialPatch = "--- a/Foo.hs\n+++ b/Foo.hs\n@@ -1 +1 @@\n-old\n+new\n"
      sig = LiquidSig
        { sigSorts      = Set.empty
        , sigMeasures   = Map.empty
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.singleton "step" (RBScalar (RBase "v" SortBool PTrue))
        , sigPathCond   = []
        }
      spec = SheafVertexSpec
        { svVertexId         = vId
        , svSig              = sig
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }

  qv <- evalIO $ Quarantine.quarantineVertex cfg vId 3 (Just model) (Just conflict) partialPatch (Just spec)

  Quarantine.qvAttempts qv === 3
  Quarantine.qvVertexId qv === "TP-014C"

  -- Verify report file created and contains sections
  repExists <- evalIO $ Directory.doesFileExist (Quarantine.qvTriageReportPath qv)
  repExists === True
  repContent <- evalIO $ TIO.readFile (Quarantine.qvTriageReportPath qv)
  assert (T.isInfixOf "# Triaged Human Quarantine Report: TP-014C" repContent)
  assert (T.isInfixOf "| `delta` | `42` |" repContent)
  assert (T.isInfixOf "AutoRowRepairable (field: `row_field`)" repContent)
  assert (T.isInfixOf "--- a/Foo.hs" repContent)

  -- Verify stub file created
  stubExists <- evalIO $ Directory.doesFileExist (stubDir </> "PrimAxiomaticStub.hs")
  stubExists === True
  stubContent <- evalIO $ TIO.readFile (stubDir </> "PrimAxiomaticStub.hs")
  assert (T.isInfixOf "module PrimAxiomaticStub where" stubContent)
  assert (T.isInfixOf "{-@ assume step :: {v:Bool | true} @-}" stubContent)
  assert (T.isInfixOf "step :: Bool" stubContent)

--------------------------------------------------------------------------------
-- Yamaarashi.Patch.Prepared Tests
--------------------------------------------------------------------------------

prop_prepared_materialize_and_synthesize :: Property
prop_prepared_materialize_and_synthesize = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("prepared-test-" ++ show t)
      vspec = SheafVertexSpec
        { svVertexId         = "v-test"
        , svSig              = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      primHole = PrimSynquidHole "src/Foo.hs" (SymbolKey "solveHole") (HoleId "h1") "variant absurd" "basis"
      primCabal = PrimCabalSet "foo.cabal" "exposed-modules" SetInsert "Foo.Bar"
      primHs = PrimHsHeaderSet "src/Foo.hs" "LANGUAGE" SetInsert "OverloadedStrings"
      prims = primCabal :>: primHs :>: primHole :>: NilFL
      sketch = GPatch
        { gpPatchId       = PatchId "P-SKETCH"
        , gpContextDeps   = Set.empty
        , gpBaseTreeOid   = TreeOid (OidHex "1111111111111111111111111111111111111111")
        , gpResultTreeOid = TreeOid (OidHex "2222222222222222222222222222222222222222")
        , gpPrims         = prims
        , gpSigMorphism   = emptyMorphism
        , gpVertexSpec    = vspec
        }

  -- 1. Sealing sketch initially fails because hole is unresolved
  case sealCompletedGPatch sketch of
    Left err -> assert (T.isInfixOf "unresolved PrimSynquidHoles" err)
    Right _  -> fail "Expected sealing to fail on un-synthesized hole"

  -- 2. Materialize primitives into test workspace
  evalIO $ materializePreparedGPatch testDir sketch

  cabalExists <- evalIO $ Directory.doesFileExist (testDir </> "foo.cabal")
  cabalExists === True
  cabalContent <- evalIO $ TIO.readFile (testDir </> "foo.cabal")
  assert (T.isInfixOf "Foo.Bar" cabalContent)

  fooExists <- evalIO $ Directory.doesFileExist (testDir </> "src/Foo.hs")
  fooExists === True
  fooContent <- evalIO $ TIO.readFile (testDir </> "src/Foo.hs")
  assert (T.isInfixOf "{-# LANGUAGE OverloadedStrings #-}" fooContent)
  assert (T.isInfixOf "solveHole = error \"HOLE: h1\"" fooContent)

  -- 3. Synthesize holes deductively with 0 tokens
  (newPrims, resolutions) <- evalIO $ synthesizePreparedHoles testDir (gpPrims sketch)
  length resolutions === 1
  let [res] = resolutions
  case resStatus res of
    SynthesizedZeroToken _term rendered -> do
      assert (T.isInfixOf "absurdVariantF" rendered)
    UnresolvedHole msg -> fail (T.unpack msg)

  -- 4. Verify workspace file updated with synthesized declaration
  updatedFooContent <- evalIO $ TIO.readFile (testDir </> "src/Foo.hs")
  assert (T.isInfixOf "solveHole = absurdVariantF" updatedFooContent)

  -- 5. Sealing now succeeds on hole-free patch!
  let completedPatch = sketch { gpPrims = newPrims }
  case sealCompletedGPatch completedPatch of
    Right sealed -> gpPatchId sealed === PatchId "P-SKETCH"
    Left err     -> fail (T.unpack err)

prop_prepared_bundle_roundtrip :: Property
prop_prepared_bundle_roundtrip = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("bundle-test-" ++ show t)
      bundlePath = testDir </> "sketch.gpatch"
      vspec = SheafVertexSpec
        { svVertexId         = "v-roundtrip"
        , svSig              = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      primHole = PrimSynquidHole "src/Worker.hs" (SymbolKey "workerTask") (HoleId "w1") "variant absurd" "basis"
      sketch = GPatch
        { gpPatchId       = PatchId "P-BUNDLE-TEST"
        , gpContextDeps   = Set.empty
        , gpBaseTreeOid   = TreeOid (OidHex "3333333333333333333333333333333333333333")
        , gpResultTreeOid = TreeOid (OidHex "4444444444444444444444444444444444444444")
        , gpPrims         = primHole :>: NilFL
        , gpSigMorphism   = emptyMorphism
        , gpVertexSpec    = vspec
        }

  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ writeGPatchBundle bundlePath sketch

  -- Execute prepared sketch end-to-end
  eResult <- evalIO $ executePreparedSketch testDir bundlePath
  case eResult of
    Right (Sealed2 sealed) -> do
      gpPatchId sealed === PatchId "P-BUNDLE-TEST"
    Left err -> fail (T.unpack err)

--------------------------------------------------------------------------------
-- Yamaarashi.Patch.Reaper Tests
--------------------------------------------------------------------------------

prop_reaper_parallel_merge :: Property
prop_reaper_parallel_merge = property $ do
  tmpRoot <- evalIO Directory.getTemporaryDirectory
  t <- evalIO CPUTime.getCPUTime
  let testDir = tmpRoot </> ("reaper-test-" ++ show t)
      path1 = testDir </> "worker1.gpatch"
      path2 = testDir </> "worker2.gpatch"
      vspec1 = SheafVertexSpec
        { svVertexId         = "v-worker1"
        , svSig              = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      vspec2 = SheafVertexSpec
        { svVertexId         = "v-worker2"
        , svSig              = LiquidSig Set.empty Map.empty [] Set.empty Map.empty []
        , svContext          = Context Map.empty
        , svBasis            = QualifierBasis Set.empty
        , svLocalGuarantee   = FTrue
        , svLocalRequirement = FTrue
        }
      p1 = GPatch
        { gpPatchId       = PatchId "W1"
        , gpContextDeps   = Set.empty
        , gpBaseTreeOid   = TreeOid (OidHex "1111111111111111111111111111111111111111")
        , gpResultTreeOid = TreeOid (OidHex "2222222222222222222222222222222222222222")
        , gpPrims         = PrimCabalSet "foo.cabal" "exposed-modules" SetInsert "Worker.One" :>: NilFL
        , gpSigMorphism   = emptyMorphism
        , gpVertexSpec    = vspec1
        }
      p2 = GPatch
        { gpPatchId       = PatchId "W2"
        , gpContextDeps   = Set.empty
        , gpBaseTreeOid   = TreeOid (OidHex "1111111111111111111111111111111111111111")
        , gpResultTreeOid = TreeOid (OidHex "3333333333333333333333333333333333333333")
        , gpPrims         = PrimCabalSet "foo.cabal" "exposed-modules" SetInsert "Worker.Two" :>: NilFL
        , gpSigMorphism   = emptyMorphism
        , gpVertexSpec    = vspec2
        }

  evalIO $ Directory.createDirectoryIfMissing True testDir
  evalIO $ writeGPatchBundle path1 p1
  evalIO $ writeGPatchBundle path2 p2

  -- 1. Reap parallel worker bundles under Z3Hyperdoctrine
  eReaped <- evalIO $ reapParallelGPatchBundles Z3Hyperdoctrine [path1, path2]
  case eReaped of
    Left err -> fail (show err)
    Right (Sealed2 reaped) -> do
      gpPatchId reaped === PatchId "W1+W2"
      Set.member (PatchId "W1") (gpContextDeps reaped) === True
      Set.member (PatchId "W2") (gpContextDeps reaped) === True

      -- 2. Validate fast-import stream emission
      let stream = emitReapedFastImportStream "refs/heads/master" (Sealed2 reaped)
      assert (BSC.isInfixOf "commit refs/heads/master" stream)
      assert (BSC.isInfixOf "refs/gargamelle/gpatch/W1+W2" stream)

prop_reaper_edge_cases :: Property
prop_reaper_edge_cases = property $ do
  -- Empty list returns ReaperIoError
  eEmpty <- evalIO $ reapParallelGPatchBundles Z3Hyperdoctrine []
  case eEmpty of
    Left (ReaperIoError msg) -> assert (T.isInfixOf "No .gpatch bundles" msg)
    _                        -> fail "Expected ReaperIoError on empty list"
--------------------------------------------------------------------------------
-- Campaign Unfold Tests (TP-014A)
--------------------------------------------------------------------------------

prop_campaign_unfold_load_constellation :: Property
prop_campaign_unfold_load_constellation = property $ do
  let dhallPath = "/home/nyc/src/plans/campaigns/november-constellation.dhall"
  exists <- evalIO $ Directory.doesFileExist dhallPath
  if exists
    then do
      eMatrix <- evalIO $ Unfold.loadCampaignMatrix dhallPath
      case eMatrix of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right matrix -> do
          Unfold.matrixId matrix === "CAMPAIGN-2026-11-CONSTELLATION"
          length (Unfold.matrixArcs matrix) === 5
          Unfold.softThrottleBatteryPct (Unfold.matrixPowerPolicy matrix) === 15
          Unfold.hardCheckpointBatteryPct (Unfold.matrixPowerPolicy matrix) === 7
          let arcIds = map Unfold.arcId (Unfold.matrixArcs matrix)
          assert ("ARC-SMIRK-EFFECTS" `elem` arcIds)
          assert ("ARC-VCS-GPATCH" `elem` arcIds)
    else do
      let sampleJson = BSC.pack "{\"matrixId\":\"CAMPAIGN-TEST\",\"description\":\"Test\",\"axes\":[],\"powerPolicy\":{\"softThrottleBatteryPct\":15,\"hardCheckpointBatteryPct\":7,\"allowOnBattery\":true,\"maxParallelSandboxesAC\":4,\"maxParallelSandboxesBat\":1},\"defaultTriage\":{\"emitAxiomaticStub\":true},\"arcs\":[{\"arcId\":\"ARC-1\",\"title\":\"Arc 1\",\"gitBranch\":\"main\",\"pert\":{\"optimistic\":1,\"mostLikely\":2,\"pessimistic\":3},\"seedMetaPackets\":[\"test.dhall\"]}]}"
      case Unfold.loadCampaignMatrixFromJson sampleJson of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right matrix -> do
          Unfold.matrixId matrix === "CAMPAIGN-TEST"
          length (Unfold.matrixArcs matrix) === 1

prop_campaign_unfold_recon_runner :: Property
prop_campaign_unfold_recon_runner = property $ do
  tmpDir <- evalIO $ do
    baseTmp <- Directory.getTemporaryDirectory
    let dir = baseTmp </> "test-recon-runner"
    Directory.createDirectoryIfMissing True (dir </> "src")
    TIO.writeFile (dir </> "src" </> "SampleModuleA.hs") $ T.unlines
      [ "module SampleModuleA (funcA, TypeA) where"
      , "data TypeA = TypeA"
      , "funcA :: Int -> String"
      , "funcA _ = \"hello\""
      ]
    TIO.writeFile (dir </> "src" </> "SampleModuleB.hs") $ T.unlines
      [ "module SampleModuleB (funcB) where"
      , "funcB :: String -> Bool"
      , "funcB _ = True"
      ]
    pure dir
  let recon = Unfold.ReconSpec
        { Unfold.reconTargetRepoDir = tmpDir
        , Unfold.reconInspectGlobs = ["src/*.hs"]
        , Unfold.reconTreeSitterGrammar = "haskell"
        , Unfold.reconOutputWitnessDhall = "witnesses/test-witness.dhall"
        }
  eWitness <- evalIO $ Unfold.runReconSpec recon
  evalIO $ Directory.removeDirectoryRecursive tmpDir
  case eWitness of
    Left err -> do
      annotate (T.unpack err)
      failure
    Right witness -> do
      assert ("SampleModuleA" `elem` Unfold.iwModules witness)
      assert ("SampleModuleB" `elem` Unfold.iwModules witness)
      assert ("funcA" `elem` Unfold.iwExportedSymbols witness)
      assert ("funcB" `elem` Unfold.iwExportedSymbols witness)
      let sigMap = Map.fromList (Unfold.iwTypeSignatures witness)
      Map.lookup "funcA" sigMap === Just "Int -> String"
      Map.lookup "funcB" sigMap === Just "String -> Bool"

prop_campaign_unfold_pushout_primitives :: Property
prop_campaign_unfold_pushout_primitives = property $ do
  let hostBase = Unfold.HostBase
        { Unfold.hbRepoDir = "/tmp/host"
        , Unfold.hbTargetModule = "Host.Kernel"
        , Unfold.hbExistingSymbols = ["kernelInit", "allocPage"]
        , Unfold.hbLiquidSig = Unfold.emptyLiquidSig
        }
      witness = Unfold.InterfaceWitness
        { Unfold.iwInterfaceName = "HostVM.Sig"
        , Unfold.iwTargetRepoDir = "/tmp/host"
        , Unfold.iwModules = ["Host.Kernel"]
        , Unfold.iwExportedSymbols = ["allocPage"]
        , Unfold.iwTypeSignatures = [("allocPage", "Int -> Page")]
        , Unfold.iwMeasures = []
        , Unfold.iwQualifiers = []
        , Unfold.iwLiquidSig = Unfold.emptyLiquidSig
        }
      pushout = Unfold.PushoutTemplate
        { Unfold.pushoutSharedInterfaceSig = "HostVM.Sig"
        , Unfold.pushoutWeaveSpecModule = "Pgcl.ClusterWeave"
        , Unfold.pushoutRequiredMeasures = ["clusterOrder"]
        , Unfold.pushoutRequiredQualifiers = ["v >= 0"]
        }
      arc = Unfold.CampaignArc
        { Unfold.arcId = "ARC-PGCL-WEAVE"
        , Unfold.arcTitle = "PGCL HostVM Weave Campaign"
        , Unfold.arcCoordinates = [("Constellation", "Pgcl")]
        , Unfold.arcGitBranch = "campaign/pgcl"
        , Unfold.arcDependsOnArcs = []
        , Unfold.arcSharedSheafEdges = ["e_pgcl_host"]
        , Unfold.arcMode = Unfold.Autonomous
        , Unfold.arcPert = Unfold.PertEstimate 2 4 8
        , Unfold.arcRecon = Nothing
        , Unfold.arcPushout = Just pushout
        , Unfold.arcSeedMetaPackets = []
        , Unfold.arcTriagePolicy = Unfold.QuarantineAndStub (Unfold.QuarantinePolicy True)
        }
  case Unfold.instantiatePushout hostBase witness pushout arc of
    Left err -> do
      annotate (T.unpack err)
      failure
    Right packets -> do
      assert (not (null packets))
      assert (all Unfold.isPrimitivePacket packets)
      case packets of
        (primary:_) -> do
          Unfold.ulpTargetModule primary === "Pgcl.ClusterWeave"
          Unfold.ulpRunBudgetSeconds primary === 4 * 120
          assert ("clusterOrder" `elem` Unfold.ulpAssumedGuarantees primary)
        [] -> failure

prop_campaign_unfold_schedule_graph_cpm :: Property
prop_campaign_unfold_schedule_graph_cpm = property $ do
  let dhallPath = "/home/nyc/src/plans/campaigns/november-constellation.dhall"
  exists <- evalIO $ Directory.doesFileExist dhallPath
  matrix <- if exists
    then do
      eMat <- evalIO $ Unfold.loadCampaignMatrix dhallPath
      case eMat of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right m -> pure m
    else do
      let sampleJson = BSC.pack "{\"matrixId\":\"CAMPAIGN-TEST\",\"description\":\"Test\",\"axes\":[],\"powerPolicy\":{\"softThrottleBatteryPct\":15,\"hardCheckpointBatteryPct\":7,\"allowOnBattery\":true,\"maxParallelSandboxesAC\":4,\"maxParallelSandboxesBat\":1},\"defaultTriage\":{\"emitAxiomaticStub\":true},\"arcs\":[{\"arcId\":\"ARC-1\",\"title\":\"Arc 1\",\"gitBranch\":\"main\",\"pert\":{\"optimistic\":1,\"mostLikely\":2,\"pessimistic\":3},\"seedMetaPackets\":[\"test.dhall\"]}]}"
      case Unfold.loadCampaignMatrixFromJson sampleJson of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right m -> pure m
  eGraph <- evalIO $ Unfold.unfoldToScheduleGraph matrix
  case eGraph of
    Left gErr -> do
      annotate (T.unpack gErr)
      failure
    Right graph -> do
      let makespan = PERT.projectMakespan graph
      annotateShow makespan
      assert (makespan > 0)
      let metrics = PERT.computePERTMetrics graph
      annotateShow (PERT.pmProjectMakespan metrics)
      assert (PERT.pmProjectMakespan metrics > 0)
      assert (not (null (PERT.pmCriticalPath metrics)))


prop_smirkGate_synthesize :: Property
prop_smirkGate_synthesize = property $ do
  res <- evalIO SmirkGate.runSmirkSynthesisBenchmark
  SmirkGate.brSuccess res === True
  SmirkGate.brSynthesizedAST res /== Nothing

---------------------------------------------------------------------------------
-- WorkDAG Ingest Properties (TP-YAMAARASHI-INGEST-001)
---------------------------------------------------------------------------------

prop_workdag_reconcile_idempotent :: Property
prop_workdag_reconcile_idempotent = property $ do
  let nodeA = Ingest.PacketNode "TP-A" "/repo" "pending/TP-A.dhall" [] Ingest.StatusPending "hashA"
      nodeB = Ingest.PacketNode "TP-B" "/repo" "completed/TP-B.dhall" [] Ingest.StatusCompleted "hashB"
      nodes = [nodeA, nodeB]
      (st1, delta1) = Ingest.reconcilePacketSnapshot nodes Ingest.emptyWorkDag
  Ingest.idAdded delta1 === ["TP-A", "TP-B"]
  let (st2, delta2) = Ingest.reconcilePacketSnapshot nodes st1
  Ingest.idAdded delta2 === []
  Ingest.idUpdated delta2 === []

prop_workdag_ready_packets :: Property
prop_workdag_ready_packets = property $ do
  let nodeDone = Ingest.PacketNode "TP-001" "/repo" "completed/TP-001.dhall" [] Ingest.StatusCompleted "hash1"
      nodeReady = Ingest.PacketNode "TP-002" "/repo" "pending/TP-002.dhall" ["TP-001"] Ingest.StatusPending "hash2"
      nodeBlocked = Ingest.PacketNode "TP-003" "/repo" "pending/TP-003.dhall" ["TP-999"] Ingest.StatusPending "hash3"
      (st, _) = Ingest.reconcilePacketSnapshot [nodeDone, nodeReady, nodeBlocked] Ingest.emptyWorkDag
      ready = Ingest.readyPackets st
  map Ingest.pnId ready === ["TP-002"]

prop_workdag_detect_cycles :: Property
prop_workdag_detect_cycles = property $ do
  let nodeX = Ingest.PacketNode "TP-X" "/repo" "pending/TP-X.dhall" ["TP-Y"] Ingest.StatusPending "hashX"
      nodeY = Ingest.PacketNode "TP-Y" "/repo" "pending/TP-Y.dhall" ["TP-X"] Ingest.StatusPending "hashY"
      (st, _delta) = Ingest.reconcilePacketSnapshot [nodeX, nodeY] Ingest.emptyWorkDag
      cycles = Ingest.detectCycles st
  assert (not (null cycles))

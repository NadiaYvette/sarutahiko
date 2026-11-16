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
import Gargamelle.Core.Institution.Liquid (LiquidModel (..), LiquidVal (..))
import Gargamelle.Sheaf.LatticeCohomology
  ( SheafVertexSpec (..)
  , H1QualifierConflict (..)
  , H1ConflictClassification (..)
  )
import Gargamelle.FOL.LiquidHyperdoctrine
  ( Context (..)
  , FOLFormula (..)
  , QualifierBasis (..)
  , QualifierConj (..)
  )
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
  , testGroup "Yamaarashi.Schedule.Quarantine"
      [ testProperty "shouldQuarantine enforces repair attempt threshold" prop_quarantine_threshold
      , testProperty "synthesizeAxiomaticStub synthesizes compileable Liquid assume contracts and error stubs" prop_quarantine_synthesis
      , testProperty "quarantineVertex records triage report, counterexample model, and writes stub module" prop_quarantine_vertex_execution
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

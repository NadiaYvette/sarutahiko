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

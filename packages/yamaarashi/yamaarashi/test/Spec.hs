{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

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

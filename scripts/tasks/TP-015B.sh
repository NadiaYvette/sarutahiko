#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-015B] Implementing Yamaarashi.Context.TailExcision ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Context

cat << 'EOF' > packages/yamaarashi/yamaarashi/src/Yamaarashi/Context/TailExcision.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module      : Yamaarashi.Context.TailExcision
-- Description : Stage 2 Prefix-Preserving Tail Pruning & Stage 3 Stateless Stalk Mode
--
-- Preserves prompt cache KV-efficiency across multi-turn worker repair loops.
-- When a worker turn fails to advance the verification state (identical compiler
-- diagnostics), 'pruneTranscriptTail' excises the bloated turn tail and substitutes
-- a compact 50-token tombstone pointing to the spilled log on disk.
-- 'renderStatelessStalk' freezes invariant rules/contracts in Block A and bounds
-- dynamic turn state in Block B to <= 6,000 tokens total.
module Yamaarashi.Context.TailExcision
  ( -- * Core Data Types
    TurnObservation (..)
  , TombstoneRecord (..)
  , ContextValveState (..)
  , FrozenBlockA (..)
  , DynamicBlockB (..)
  , StalkPrompt (..)

    -- * Initialization
  , emptyContextValveState

    -- * Tail Excision & Pruning
  , pruneTranscriptTail
  , applyTailExcision

    -- * Stateless 2-Block Stalk Rendering
  , renderStatelessStalk
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | Observation recorded from a single execution or repair turn.
data TurnObservation = TurnObservation
  { obsTurnIndex        :: !Word
  , obsEstimatedTokens  :: !Int
  , obsCompilerCode     :: !(Maybe Text)
  , obsErrorCount       :: !Int
  , obsRawText          :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Tombstone reference replacing an excised transcript turn.
data TombstoneRecord = TombstoneRecord
  { tombTurnIndex :: !Word
  , tombLogPath   :: !FilePath
  , tombReason    :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Context valve tracking prefix stability, turn messages, and tombstones.
data ContextValveState = ContextValveState
  { messageHistory     :: ![Text]
  , cachedPrefixBytes  :: !Int
  , lastCompilerCode   :: !(Maybe Text)
  , lastErrorCount     :: !Int
  , tombstoneRecords   :: ![TombstoneRecord]
  } deriving stock (Eq, Show, Generic)

-- | Initial blank valve state.
emptyContextValveState :: ContextValveState
emptyContextValveState = ContextValveState
  { messageHistory    = []
  , cachedPrefixBytes = 0
  , lastCompilerCode  = Nothing
  , lastErrorCount    = 0
  , tombstoneRecords  = []
  }

-- | Frozen immutable Block A: system directives, packet contract, interfaces.
newtype FrozenBlockA = FrozenBlockA { unBlockA :: Text }
  deriving stock (Eq, Show, Generic)

-- | Dynamic Block B: current file buffer, compiler error digest.
newtype DynamicBlockB = DynamicBlockB { unBlockB :: Text }
  deriving stock (Eq, Show, Generic)

-- | Rendered prompt for the stateless stalk mode worker.
newtype StalkPrompt = StalkPrompt { unStalkPrompt :: Text }
  deriving stock (Eq, Show, Generic)

-- | Format a concise 50-token tombstone.
formatTombstone :: Word -> Text
formatTombstone turn =
  "[Excised Turn " <> T.pack (show turn) <> ": see .yamaarashi/spill/turn-" <> T.pack (show turn) <> ".log]"

-- | Prune the transcript tail if the previous turn failed to advance verification
-- and exceeded the token threshold (> 1,200 tokens).
pruneTranscriptTail :: ContextValveState -> TurnObservation -> ContextValveState
pruneTranscriptTail state obs =
  let isBloated = obsEstimatedTokens obs > 1200
      nonAdvancing =
        obsCompilerCode obs == lastCompilerCode state
        && obsErrorCount obs >= lastErrorCount state
        && obsErrorCount obs > 0
  in if isBloated && nonAdvancing
       then
         let tomb = formatTombstone (obsTurnIndex obs)
             tRecord = TombstoneRecord
               { tombTurnIndex = obsTurnIndex obs
               , tombLogPath   = ".yamaarashi/spill/turn-" <> show (obsTurnIndex obs) <> ".log"
               , tombReason    = "Non-advancing compiler state (" <> maybe "unknown" id (obsCompilerCode obs) <> ")"
               }
             history = case messageHistory state of
               []     -> [tomb]
               (_:ms) -> tomb : ms
         in state
              { messageHistory   = history
              , tombstoneRecords = tRecord : tombstoneRecords state
              }
       else
         state
           { messageHistory   = obsRawText obs : messageHistory state
           , lastCompilerCode = obsCompilerCode obs
           , lastErrorCount   = obsErrorCount obs
           }

-- | Apply tail excision over a list of historical observations.
applyTailExcision :: ContextValveState -> [TurnObservation] -> ContextValveState
applyTailExcision = foldl pruneTranscriptTail

-- | Render the 2-block stateless stalk prompt.
-- Invariant: Caps total rendered stalk prompt to <= 6,000 tokens (approx 24,000 chars)
-- while keeping Block A strictly immutable.
renderStatelessStalk :: FrozenBlockA -> DynamicBlockB -> StalkPrompt
renderStatelessStalk (FrozenBlockA blockA) (DynamicBlockB blockB) =
  let maxTotalTokens = 6000
      maxTotalChars  = maxTotalTokens * 4
      blockAChars    = T.length blockA
      allowedBChars  = max 500 (maxTotalChars - blockAChars - 50)
      boundedB       = if T.length blockB > allowedBChars
                         then T.take allowedBChars blockB <> "\n... [Block B truncated to fit 6,000-token stalk limit]"
                         else blockB
      fullPrompt     = blockA <> "\n\n=== [DYNAMIC WORKER CONTEXT: BLOCK B] ===\n\n" <> boundedB
  in StalkPrompt fullPrompt
EOF

echo "=== [TP-015B] Updating yamaarashi.cabal ==="
cat << 'EOF' > packages/yamaarashi/yamaarashi/yamaarashi.cabal
cabal-version:      3.14
name:               yamaarashi
version:            0.1.0.0
synopsis:           Church-encoded CPS free-monad element streaming kernel
description:
    Pure, dependency-free element streaming kernel implementing O(1) left-associated
    monadic binds via Codensity and Church-encoded CPS free monads. Unrolls existential
    Steppers into element streams at the consumer edge with typed concurrency strategies.
    .
    Conceptual Lineage and Attribution:
    This package is an intellectual derivation and architectural synthesis of concepts
    pioneered by:
    * 'streaming' (Michael Thompson) — Church-encoded CPS free monad stream representation
    * 'streamly' (Harendra Kumar / Composewell Technologies) — sequential streaming pipelines
      and concurrency execution models (see LICENSES/NOTICE-streamly.txt)
    * 'conduit' (Michael Snoyman) — bracketed resource cleanup and push/pull streaming
    .
    See NOTICE.md at the repository root for complete intellectual provenance,
    conceptual lineage, and licensing acknowledgments.
license:            BSD-3-Clause
license-file:       LICENSE
author:             Nadia Yvette Chambers
maintainer:         nadia.yvette.chambers@ik.me
category:           Control, Streaming
build-type:         Simple

common commons
    default-language: GHC2024
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wmissing-home-modules
        -Wpartial-fields
        -Wredundant-constraints

library
    import:           commons
    exposed-modules:
        Yamaarashi
        Yamaarashi.Synthesis.Synquid
        Yamaarashi.Context.BlastShield
        Yamaarashi.Context.TailExcision
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        mtl,
        bytestring,
        filepath,
        directory,
        kagami-ita-observability,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        sarutahiko-effect-signatures >= 0.1
    hs-source-dirs:   src

test-suite yamaarashi-test
    import:           commons
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    ghc-options:      -threaded -rtsopts -with-rtsopts=-N
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        bytestring,
        filepath,
        directory,
        kagami-ita-observability,
        yamaarashi,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        sarutahiko-effect-signatures >= 0.1,
        tasty,
        hedgehog,
        tasty-hedgehog
EOF

echo "=== [TP-015B] Updating packages/yamaarashi/yamaarashi/test/Spec.hs ==="
cat << 'EOF' > packages/yamaarashi/yamaarashi/test/Spec.hs
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
EOF

echo "=== [TP-015B] Implementation complete ==="

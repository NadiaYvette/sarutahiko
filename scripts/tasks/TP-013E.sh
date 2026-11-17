#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-013E] Implementing Yamaarashi.Patch.Reaper ==="

SARU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YAMA_DIR="$SARU_DIR/packages/yamaarashi/yamaarashi"

mkdir -p "$YAMA_DIR/src/Yamaarashi/Patch"

# 1. Update yamaarashi.cabal to expose Yamaarashi.Patch.Reaper
cat << 'EOF' > "$YAMA_DIR/yamaarashi.cabal"
cabal-version:      3.14
name:               yamaarashi
version:            0.1.0.0
synopsis:           Church-encoded CPS free-monad element streaming kernel
description:
    Pure, dependency-free element streaming kernel implementing O(1) left-associated
    monadic binds via Codensity and Church-encoded CPS free monads. Unrolls existential
    Steppers into element streams at the consumer edge with typed concurrency strategies.
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
        Yamaarashi.Sandbox.Airgap
        Yamaarashi.Executor.DeterministicSplicer
        Yamaarashi.Daemon.PowerAndWAL
        Yamaarashi.Schedule.TropicalPERT
        Yamaarashi.Schedule.Quarantine
        Yamaarashi.Patch.Prepared
        Yamaarashi.Patch.Reaper
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        mtl,
        bytestring,
        filepath,
        directory,
        process,
        kagami-ita-observability,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        gargamelle-sheaf,
        gargamelle-evidence,
        gargamelle-equational,
        darcs-witnesses,
        darcs-prim-structural,
        git-bundle-pure,
        sarutahiko-effect-signatures >= 0.1,
        direct-sqlite >= 2.3
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
        process,
        kagami-ita-observability,
        yamaarashi,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        gargamelle-sheaf,
        gargamelle-evidence,
        gargamelle-equational,
        darcs-witnesses,
        darcs-prim-structural,
        git-bundle-pure,
        sarutahiko-effect-signatures >= 0.1,
        direct-sqlite >= 2.3,
        tasty,
        hedgehog,
        tasty-hedgehog
EOF

# 2. Implement Yamaarashi.Patch.Reaper
cat << 'EOF' > "$YAMA_DIR/src/Yamaarashi/Patch/Reaper.hs"
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Module      : Yamaarashi.Patch.Reaper
-- Description : Outbound Commutative Sandbox Reaper for Parallel Workers
--
-- Collects sealed .gpatch bundles emitted by concurrent worker sandboxes
-- (e.g., TP-SMIRK-003A..003E running concurrently against the same base commit).
--
-- Folds collected GPatches via mergeGPatchParallel:
-- 1. Commutes PrimCabalSet, PrimHsHeaderSet, and disjoint PrimAstDPO edits
--    without line-hunk collision or git rebase invocation.
-- 2. Enforces global H^1 = 0 cohomology across the merged wave.
-- 3. Emits canonical Git fast-import stream for atomic branch advancement.
module Yamaarashi.Patch.Reaper
  ( -- * Reaper Error & Result Types
    ReaperError (..)
  , ReaperResult (..)

    -- * Core Reaper Operations
  , reapParallelGPatchBundles
  , foldParallelGPatches
  , mergePairwiseGPatches
  , emitReapedFastImportStream
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Darcs.Patch.Witnesses
  ( FL (..)
  , (+>+)
  , (:\/:) (..)
  , (:/\:) (..)
  , Sealed2 (..)
  , seal2
  )
import Gargamelle.Evidence.Patch.Prim
  ( PatchId (..)
  , PrimPatch (..)
  )
import Gargamelle.Evidence.Patch.Bundle
  ( GPatch (..)
  , mergeGPatchParallel
  , readGPatchBundle
  )
import Gargamelle.Evidence.GitBundle
  ( TreeOid (..)
  , emitGitFastImportStream
  , gpatchRefPrefix
  )
import Gargamelle.FOL.LiquidHyperdoctrine
  ( Hyperdoctrine (..)
  , LiquidSubHyperdoctrine (..)
  )
import Gargamelle.Sheaf.LatticeCohomology
  ( SheafVertexSpec (..)
  )
import Unsafe.Coerce (unsafeCoerce)

-- | Error during parallel wave reaping.
data ReaperError
  = ReaperCohomologyObstruction !Text
  | ReaperCommuteConflict !Text
  | ReaperIoError !Text
  deriving (Eq, Show)

-- | Result of parallel wave reaping.
data ReaperResult = ReaperResult
  { rrCombinedPatch :: !(Sealed2 GPatch)
  , rrMergedCount   :: !Int
  , rrFastImport    :: !ByteString
  }

instance Show ReaperResult where
  show (ReaperResult (Sealed2 gp) cnt _) =
    "ReaperResult { rrCombinedPatch = " ++ show (gpPatchId gp) ++ ", rrMergedCount = " ++ show cnt ++ " }"

-- | Reap a list of .gpatch bundle files from disk, merging them in parallel.
reapParallelGPatchBundles
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> [FilePath]
  -> IO (Either ReaperError (Sealed2 GPatch))
reapParallelGPatchBundles _ [] =
  pure $ Left (ReaperIoError "No .gpatch bundles provided to reaper")
reapParallelGPatchBundles _ [singlePath] = do
  sealed <- readGPatchBundle singlePath
  pure $ Right sealed
reapParallelGPatchBundles h paths = do
  bundles <- mapM readGPatchBundle paths
  foldParallelGPatches h bundles

-- | Fold a list of Sealed2 GPatches that share the same base commit.
foldParallelGPatches
  :: (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> [Sealed2 GPatch]
  -> IO (Either ReaperError (Sealed2 GPatch))
foldParallelGPatches _ [] =
  pure $ Left (ReaperIoError "Empty list of patches passed to foldParallelGPatches")
foldParallelGPatches _ [single] =
  pure $ Right single
foldParallelGPatches h (firstPatch : rest) = go firstPatch rest 1
  where
    go acc [] _ = pure $ Right acc
    go (Sealed2 (pAcc :: GPatch wX wA)) (Sealed2 pNext : ps) idx = do
      mMerged <- mergePairwiseGPatches h pAcc (unsafeCoerce pNext)
      case mMerged of
        Nothing ->
          pure $ Left (ReaperCohomologyObstruction
            ("mergeGPatchParallel failed with non-zero cohomology or syntactic conflict at index " <> T.pack (show idx)))
        Just combinedSealed ->
          go combinedSealed ps (idx + 1)

-- | Pairwise merge of two parallel GPatches under Hyperdoctrine.
-- Combines their primitives, accumulates dependencies, and advances result tree.
mergePairwiseGPatches
  :: forall h wX wA wB. (Hyperdoctrine h, LiquidSubHyperdoctrine h)
  => h
  -> GPatch wX wA
  -> GPatch wX wB
  -> IO (Maybe (Sealed2 GPatch))
mergePairwiseGPatches h p1 p2 = do
  mMerged <- mergeGPatchParallel h (p1 :\/: p2)
  case mMerged of
    Nothing -> pure Nothing
    Just (p2' :/\: _p1') -> do
      -- Combined patch primitives: p1 followed by p2'
      let combinedPrims = gpPrims p1 +>+ gpPrims p2'
          combinedDeps = Set.unions [gpContextDeps p1, gpContextDeps p2, Set.singleton (gpPatchId p1), Set.singleton (gpPatchId p2)]
          combinedId = PatchId (unPatchId (gpPatchId p1) <> "+" <> unPatchId (gpPatchId p2))
          combinedSpec = SheafVertexSpec
            { svVertexId         = svVertexId (gpVertexSpec p1) <> "+" <> svVertexId (gpVertexSpec p2)
            , svSig              = svSig (gpVertexSpec p1)
            , svContext          = svContext (gpVertexSpec p1)
            , svBasis            = svBasis (gpVertexSpec p1)
            , svLocalGuarantee   = svLocalGuarantee (gpVertexSpec p1)
            , svLocalRequirement = svLocalRequirement (gpVertexSpec p1)
            }
          combinedPatch = GPatch
            { gpPatchId       = combinedId
            , gpContextDeps   = combinedDeps
            , gpBaseTreeOid   = gpBaseTreeOid p1
            , gpResultTreeOid = gpResultTreeOid p2'
            , gpPrims         = combinedPrims
            , gpSigMorphism   = gpSigMorphism p1
            , gpVertexSpec    = combinedSpec
            }
      pure (Just (seal2 combinedPatch))

-- | Emit Git fast-import stream for a reaped GPatch bundle.
emitReapedFastImportStream :: ByteString -> Sealed2 GPatch -> ByteString
emitReapedFastImportStream branchRef (Sealed2 gp) =
  let pIdBytes = unPatchId (gpPatchId gp)
      gpatchRef = gpatchRefPrefix <> pIdBytes
      commitMsg = "Reaped parallel wave: " <> pIdBytes <> "\n\nAssisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)\nOrchestrated-by: Yamaarashi Flow Task Runner\n"
      metaPayload = "{\"patch_id\": \"" <> pIdBytes <> "\", \"reaped\": true, \"cohomology_H1\": 0}"
      commits =
        [ (branchRef, commitMsg, [("REAPED_GPATCH.txt", pIdBytes)])
        , (gpatchRef, "GPatch metadata ref", [("metadata.json", metaPayload)])
        ]
  in emitGitFastImportStream commits
EOF

# 3. Add tests to test/Spec.hs in yamaarashi
if ! grep -q "Yamaarashi.Patch.Reaper" "$YAMA_DIR/test/Spec.hs"; then
  sed -i '/import Yamaarashi.Patch.Prepared/i \
import qualified Data.ByteString.Char8 as BSC\
import Yamaarashi.Patch.Reaper\
  ( ReaperError(..)\
  , reapParallelGPatchBundles\
  , foldParallelGPatches\
  , emitReapedFastImportStream\
  )\
' "$YAMA_DIR/test/Spec.hs"
fi

if ! grep -q "Z3Hyperdoctrine" "$YAMA_DIR/test/Spec.hs"; then
  sed -i '/QualifierConj (..)/a \  , Z3Hyperdoctrine (..)' "$YAMA_DIR/test/Spec.hs"
fi

if ! grep -q "Yamaarashi.Patch.Reaper Tests" "$YAMA_DIR/test/Spec.hs"; then
cat << 'EOF' >> "$YAMA_DIR/test/Spec.hs"

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
EOF

# Add Reaper test group to tests in test/Spec.hs
sed -i '/testGroup "Yamaarashi.Patch.Prepared"/i \  , testGroup "Yamaarashi.Patch.Reaper"\n      [ testProperty "reaps and merges parallel worker .gpatch bundles under Z3Hyperdoctrine" prop_reaper_parallel_merge\n      , testProperty "handles empty bundle list and edge cases gracefully" prop_reaper_edge_cases\n      ]' "$YAMA_DIR/test/Spec.hs"
fi

echo "=== [TP-013E] Completed successfully ==="

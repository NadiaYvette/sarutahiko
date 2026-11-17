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

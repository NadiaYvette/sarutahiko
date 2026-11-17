-- VERBATIM_CODE_SEED: TP-008A
-- TARGET_REPO: ~/src/sarutahiko
-- TARGET_PACKAGE: hashigakari, gargamelle-persistence
-- TARGET_FILES:
--   src/Sarutahiko/Hashigakari/Store.hs

{-# LANGUAGE BangPatterns, DeriveGeneric #-}

module Sarutahiko.Hashigakari.Store
  ( DbId(..)
  , HyperNode(..)
  , WALEntry(..)
  , HashigakariStore(..)
  , computeMerkleDbId
  , emptyHashigakariStore
  , checkoutMVCCSnapshot
  , lookupNodeById
  , commitMerkleRegion
  ) where

import Data.Bits (xor)
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Generics (Generic)

import Pukinos.Tree.BPlus
  ( EpochId
  , BPlusMap
  , emptyBPlus
  , lookupBPlus
  )
import Pukinos.Tree.FAST (lookupFAST)
import Pukinos.Effect.Penelope
  ( MVCCSnapshot(..)
  , withTransientEpoch
  , mvccSnapshot
  )

-- | 64-bit content-addressed Merkle identifier for every AST / Penelope region node.
newtype DbId = DbId { unDbId :: Word64 }
  deriving (Show, Eq, Ord, Generic)

-- | Normalized hypergraph node stored inside `HashigakariStore`.
data HyperNode = HyperNode
  { hnId          :: {-# UNPACK #-} !DbId
  , hnSymbolName  :: !Text
  , hnDialectTag  :: !Text
  , hnChildIds    :: ![DbId]
  , hnStalkHash   :: {-# UNPACK #-} !Word64
    -- ^ Hash of the node's boundary signature stalk $\mathcal{F}(u)$ for early cutoff!
  , hnPayloadText :: !Text
  } deriving (Show, Eq, Generic)

-- | Crash-only SQLite / Beam Write-Ahead Log (WAL) record (`TP-014D` compatible).
data WALEntry = WALEntry
  { walEpoch     :: {-# UNPACK #-} !EpochId
  , walRootDbId  :: {-# UNPACK #-} !DbId
  , walAddedNodes :: ![HyperNode]
  } deriving (Show, Eq, Generic)

-- | Two-tier codebase database pairing in-core `Pukinos` MVCC trees with a crash-only WAL.
data HashigakariStore = HashigakariStore
  { hsCurrentSnap :: !(MVCCSnapshot DbId HyperNode)
  , hsSymbolIndex :: !(BPlusMap Text DbId)
  , hsWAL         :: ![WALEntry]
  } deriving (Show, Eq)

-- | Deterministic 64-bit FNV-1a Merkle hash combining node tag, payload, and child `DbId`s.
computeMerkleDbId :: Text -> Text -> [DbId] -> DbId
computeMerkleDbId !dialect !payload !children =
  let !fnvOffset = 14695981039346656037 :: Word64
      !fnvPrime  = 1099511628211        :: Word64
      hashStep !h !w = (h `xor` w) * fnvPrime
      !h1 = T.foldl' (\h c -> hashStep h (fromIntegral (ord c))) fnvOffset dialect
      !h2 = T.foldl' (\h c -> hashStep h (fromIntegral (ord c))) h1 payload
      !h3 = foldl'   (\h (DbId cid) -> hashStep h cid) h2 children
  in DbId h3

emptyHashigakariStore :: HashigakariStore
emptyHashigakariStore = HashigakariStore
  { hsCurrentSnap = mvccSnapshot 0 True emptyBPlus
  , hsSymbolIndex = emptyBPlus
  , hsWAL         = []
  }

-- | O(1) lockless MVCC snapshot checkout for IDE / LSP readers and parallel synthesis agents.
{-# INLINE checkoutMVCCSnapshot #-}
checkoutMVCCSnapshot :: HashigakariStore -> MVCCSnapshot DbId HyperNode
checkoutMVCCSnapshot = hsCurrentSnap

-- | Fast node lookup using the materialized `FASTMap` accelerator when present,
--   falling back to `BPlusMap`.
lookupNodeById :: DbId -> MVCCSnapshot DbId HyperNode -> Maybe HyperNode
lookupNodeById !dbId (MVCCSnapshot _ !btree !mFast) =
  case mFast of
    Just !fast -> lookupFAST dbId fast
    Nothing    -> lookupBPlus dbId btree

-- | Commit a batch of hypergraph nodes inside a single `OpH #PukinosBatch` transient epoch,
--   updating the `FASTMap` read accelerator and appending a crash-only `WALEntry`.
commitMerkleRegion
  :: Bool          -- ^ Rebuild `FASTMap` Eytzinger cache-line index on commit
  -> [HyperNode]   -- ^ New or updated hypergraph nodes
  -> HashigakariStore
  -> (DbId, HashigakariStore)
commitMerkleRegion !rebuildFast !nodes !store =
  let MVCCSnapshot !curEp !baseTree _ = hsCurrentSnap store
      (!nextEp, !newTree) =
        withTransientEpoch curEp baseTree $ \_ep insFn tree0 ->
          foldl' (\acc n -> insFn (hnId n) n acc) tree0 nodes
      !newSymIdx =
        snd $ withTransientEpoch curEp (hsSymbolIndex store) $ \_ep insFn sym0 ->
          foldl' (\acc n -> insFn (hnSymbolName n) (hnId n) acc) sym0 nodes
      !rootId = case nodes of
        (top : _) -> hnId top
        []        -> DbId 0
      !newSnap = mvccSnapshot nextEp rebuildFast newTree
      !walRec  = WALEntry
        { walEpoch      = nextEp
        , walRootDbId   = rootId
        , walAddedNodes = nodes
        }
  in ( rootId
     , HashigakariStore
         { hsCurrentSnap = newSnap
         , hsSymbolIndex = newSymIdx
         , hsWAL         = walRec : hsWAL store
         }
     )
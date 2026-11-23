-- VERBATIM_CODE_SEED: TP-008C
-- TARGET_REPO: ~/src/sarutahiko
-- TARGET_PACKAGE: hashigakari, gargamelle-sheaf
-- TARGET_FILES:
--   src/Sarutahiko/Hashigakari/EditConeLSP.hs

{-# LANGUAGE BangPatterns, OverloadedStrings #-}

module Hashigakari.EditConeLSP
  ( CutoffDecision(..)
  , SheafEdgeLink(..)
  , ConcurrentMergeError(..)
  , EditConeQuery(..)
  , EditConeResponse(..)
  , checkEarlyCutoffStalk
  , reconcileConcurrentDbPushout
  , serveEditConeLSP
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)

import Pukinos.Tree.BPlus (BPlusMap, toAscListBPlus)
import Pukinos.Effect.Penelope
  ( MVCCSnapshot(..)
  , PushoutConflict(..)
  , commitEpochPushout
  )
import Hashigakari.Store
  ( DbId(..)
  , HyperNode(..)
  , lookupNodeById
  )

-- | Early-Cutoff decision when a node's body is edited inside `HashigakariStore`.
data CutoffDecision
  = CutoffHaltAtNode !DbId
    -- ^ Node body (`DbId`) changed, but its boundary stalk hash $H^0(\mathcal{F}(u))$ is identical!
    --   Zero callers in the reverse dependency cone need re-typechecking or recompilation.
  | CutoffPropagateEditCone ![DbId]
    -- ^ Boundary stalk changed; re-evaluate only the immediate callers in the edit cone.
  deriving (Show, Eq)

-- | Directed call-graph edge $e = (u \to v)$ carrying an expected callee stalk hash.
data SheafEdgeLink = SheafEdgeLink
  { selCallerId          :: {-# UNPACK #-} !DbId
  , selCalleeId          :: {-# UNPACK #-} !DbId
  , selExpectedStalkHash :: {-# UNPACK #-} !Word64
  } deriving (Show, Eq)

-- | Errors capable of rejecting a concurrent multi-agent database commit:
--   1. Structural `DbId` collision (`PushoutConflict` in `Pukinos`).
--   2. Semantic $H^1$ sheaf coboundary obstruction ($\delta^0 \neq \top$) along an edge $e = (u \to v)$.
data ConcurrentMergeError
  = ErrStructuralPushout ![PushoutConflict DbId HyperNode]
  | ErrSheafCoboundaryH1 ![(DbId, DbId, Word64, Word64)]
    -- ^ `(callerId, calleeId, expectedStalkHash, actualCalleeStalkHash)`
  deriving (Show, Eq)

data EditConeQuery
  = QueryHoverById     !DbId
  | QueryNodesByDialect !Text
  | QueryActiveHoles
  deriving (Show, Eq)

data EditConeResponse
  = RespHover       !Text !Word64 !Text
  | RespNodeList    ![HyperNode]
  | RespNotFound    !DbId
  deriving (Show, Eq)

-- | Checks whether mutating `oldNode` to `newNode` requires recompiling downstream callers:
--   If `hnStalkHash oldNode == hnStalkHash newNode`, halts propagation immediately in O(1)!
checkEarlyCutoffStalk
  :: HyperNode
  -> HyperNode
  -> [SheafEdgeLink]  -- ^ Call graph edges
  -> CutoffDecision
checkEarlyCutoffStalk !oldNode !newNode !edges
  | hnStalkHash oldNode == hnStalkHash newNode =
      CutoffHaltAtNode (hnId newNode)
  | otherwise =
      let !targetSym = hnSymbolName oldNode
          !callers   = [ selCallerId e
                       | e <- edges
                       , selCalleeId e == hnId oldNode || hnSymbolName newNode == targetSym
                       ]
      in CutoffPropagateEditCone callers

-- | Reconciles two concurrent worker/agent database branches (`v1` and `v2`) forked from `v0`:
--   1. Computes the structural tree pushout $V_1 \sqcup_{V_0} V_2$ via `commitEpochPushout`.
--   2. Evaluates the Tarski-Laplace sheaf coboundary $\delta^0$ across all call-graph edges
--      in the merged snapshot to catch semantic conflicts where Worker 1 changed a callee's
--      signature stalk while Worker 2 added a call assuming the old stalk!
reconcileConcurrentDbPushout
  :: MVCCSnapshot DbId HyperNode
  -> BPlusMap DbId HyperNode
  -> BPlusMap DbId HyperNode
  -> [SheafEdgeLink]
  -> Either ConcurrentMergeError (MVCCSnapshot DbId HyperNode)
reconcileConcurrentDbPushout !baseSnap !branch1 !branch2 !callEdges =
  case commitEpochPushout baseSnap branch1 branch2 of
    Left !structConflicts ->
      Left (ErrStructuralPushout structConflicts)
    Right !mergedSnap ->
      let !h1Obstructions =
            foldl'
              (\acc (SheafEdgeLink !u !v !expectedHash) ->
                case lookupNodeById v mergedSnap of
                  Nothing -> acc
                  Just !calleeNode
                    | hnStalkHash calleeNode == expectedHash -> acc
                    | otherwise ->
                        (u, v, expectedHash, hnStalkHash calleeNode) : acc)
              []
              callEdges
      in case h1Obstructions of
           []  -> Right mergedSnap
           obs -> Left (ErrSheafCoboundaryH1 (reverse obs))

-- | Lockless O(1)-snapshot LSP query responder:
--   Answers hover, dialect search, and active `ParseHole` diagnostics directly from
--   an `MVCCSnapshot` without blocking concurrent compiler or `yamaarashi` worker threads.
serveEditConeLSP
  :: MVCCSnapshot DbId HyperNode
  -> EditConeQuery
  -> EditConeResponse
serveEditConeLSP !snap (QueryHoverById !dbId) =
  case lookupNodeById dbId snap of
    Nothing -> RespNotFound dbId
    Just !n -> RespHover (hnSymbolName n) (hnStalkHash n) (hnPayloadText n)
serveEditConeLSP (MVCCSnapshot _ !btree _) (QueryNodesByDialect !dialectTag) =
  let !matches =
        [ n
        | (_, n) <- toAscListBPlus btree
        , hnDialectTag n == dialectTag
        ]
  in RespNodeList matches
serveEditConeLSP (MVCCSnapshot _ !btree _) QueryActiveHoles =
  let !holes =
        [ n
        | (_, n) <- toAscListBPlus btree
        , ":ParseHole" `T.isSuffixOf` hnDialectTag n
        ]
  in RespNodeList holes
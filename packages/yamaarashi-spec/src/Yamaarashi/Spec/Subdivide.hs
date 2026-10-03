{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Yamaarashi.Spec.Subdivide
-- Description : Corecursive task subdivision via recursion-schemes
--
-- Recursively decomposes macroscopic workflow goals into primitive, verifiable
-- leaf task packets using 'hylo' and an 'IsPrimitive' heuristic per
-- YAMAARASHI_DESIGN.md §1 and TASK_PACKET_BEST_PRACTICES.md.
module Yamaarashi.Spec.Subdivide
  ( -- * Granularity Scoring
    IsPrimitive (..)
    -- * Recursive Task Unfolding
  , TaskTreeF (..)
  , subdivideSpec
    -- * Task Packet Serialization
  , renderTaskPacketYaml
  ) where

import Data.Functor.Foldable (hylo)
import Data.Text (Text)
import qualified Data.Text as T
import Sarutahiko.Effect.TaskQueue (TaskId (..))
import Yamaarashi.Spec.Types (AtomicTask (..), SpecNode (..))

-- | Heuristic predicate determining if a specification node is atomic / primitive.
--
-- A task is primitive if it targets a single verification gate without nested decomposition.
class IsPrimitive a where
  isPrimitive :: a -> Bool

instance IsPrimitive SpecNode where
  isPrimitive = \case
    AtomicSpec {}       -> True
    ParallelSpecs []    -> True
    SequentialSpecs []  -> True
    ParallelSpecs _     -> False
    SequentialSpecs _   -> False
    ConditionalSpec {}  -> False

-- | Base functor for task hierarchy trees.
data TaskTreeF a
  = LeafTaskF !AtomicTask
  | BranchTaskF !Text ![a]
  deriving stock (Functor, Foldable, Traversable)

-- | Corecursive unfolding coalgebra: expands non-primitive nodes into subtrees.
unfoldStep :: SpecNode -> TaskTreeF SpecNode
unfoldStep node
  | isPrimitive node = case node of
      AtomicSpec tid desc res mVerify ->
        LeafTaskF (AtomicTask tid desc desc res mVerify)
      ParallelSpecs [] ->
        BranchTaskF "empty" []
      SequentialSpecs [] ->
        BranchTaskF "empty" []
      _ ->
        LeafTaskF (AtomicTask (TaskId "atomic") "Atomic" "Atomic" [] Nothing)
  | otherwise = case node of
      ParallelSpecs nodes      -> BranchTaskF "parallel" nodes
      SequentialSpecs nodes    -> BranchTaskF "sequential" nodes
      ConditionalSpec cond t e -> BranchTaskF ("cond: " <> cond) [t, e]
      AtomicSpec tid desc res mVerify ->
        LeafTaskF (AtomicTask tid desc desc res mVerify)

-- | Catamorphic folding algebra: gathers all atomic leaf tasks.
collectLeaves :: TaskTreeF [AtomicTask] -> [AtomicTask]
collectLeaves = \case
  LeafTaskF taskItem     -> [taskItem]
  BranchTaskF _ sublists -> concat sublists

-- | Corecursively decompose any specification AST into atomic leaf tasks.
--
-- Guarantees termination and that all returned items are atomic.
subdivideSpec :: SpecNode -> [AtomicTask]
subdivideSpec = hylo collectLeaves unfoldStep

-- | Render an 'AtomicTask' into canonical Task Packet YAML string conforming to
-- TASK_PACKET_BEST_PRACTICES.md.
renderTaskPacketYaml :: AtomicTask -> Text
renderTaskPacketYaml taskItem = T.unlines
  [ "---"
  , "id: " <> unTaskId (atomicId taskItem)
  , "title: " <> atomicTitle taskItem
  , "description: |"
  , "  " <> atomicDescription taskItem
  , ""
  , "dependencies: []"
  , ""
  , "packages: []"
  , ""
  , "steps:"
  , "  - id: execute"
  , "    name: Execute task step"
  , "    action: |"
  , "      " <> atomicDescription taskItem
  , "    duration: \"30m\""
  , ""
  , "success_criteria:"
  , "  - " <> maybe "Verification step passes" id (atomicVerify taskItem)
  ]

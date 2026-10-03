{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Spec.VirtualTree
-- Description : Static dependency analysis via Control.Selective.Over
--
-- Evaluates the complete resource over-approximation ('VirtualTree') across
-- all branches of a specification AST prior to runtime per YAMAARASHI_DESIGN.md §2.1.
module Yamaarashi.Spec.VirtualTree
  ( walkSpecSelective
  , walkSpecSelectiveWith
  , walkSpecOver
  , extractVirtualTree
  ) where

import Control.Selective (Over (..), Selective (..), ifS, getOver)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Yamaarashi.Spec.Types (ResourceDescriptor, SpecNode (..), VirtualTree (..))

-- | Pure static analysis walker parameterized over any 'Selective' functor,
-- recording resources and evaluating conditions.
walkSpecSelectiveWith
  :: Selective f
  => ([ResourceDescriptor] -> f ())
  -> (Text -> f Bool)
  -> SpecNode
  -> f ()
walkSpecSelectiveWith recordRes evalCond = go
  where
    go = \case
      AtomicSpec _ _ res _ -> recordRes res
      ParallelSpecs nodes ->
        foldr (\n acc -> go n *> acc) (pure ()) nodes
      SequentialSpecs nodes ->
        foldr (\n acc -> go n *> acc) (pure ()) nodes
      ConditionalSpec cond thenBranch elseBranch ->
        ifS (evalCond cond) (go thenBranch) (go elseBranch)

-- | Pure walker with default static condition resolution.
walkSpecSelective :: Selective f => ([ResourceDescriptor] -> f ()) -> SpecNode -> f ()
walkSpecSelective recordRes = walkSpecSelectiveWith recordRes (\_ -> pure True)

-- | Static traversal over 'Over (Set ResourceDescriptor)' calculating the strict
-- union of all resources.
walkSpecOver :: SpecNode -> Over (Set ResourceDescriptor) ()
walkSpecOver = walkSpecSelective (Over . Set.fromList)

-- | Extract the strict union of all required resources across all branches
-- without executing any IO or spawning any external processes.
extractVirtualTree :: SpecNode -> VirtualTree
extractVirtualTree node = VirtualTree (getOver (walkSpecOver node))

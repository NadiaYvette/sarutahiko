{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Yamaarashi.Spec.Types
-- Description : Specification AST and Resource Descriptors
--
-- Pure algebraic data types modeling task specifications, inert resource
-- descriptors, and virtual tree over-approximations per YAMAARASHI_DESIGN.md §2.1.
module Yamaarashi.Spec.Types
  ( -- * Pure Inert Resource Descriptors
    ResourceDescriptor (..)
  , VirtualTree (..)
    -- * Specification AST
  , SpecNode (..)
  , TaskSpec (..)
  , AtomicTask (..)
  ) where

import Data.Set (Set)
import Data.Text (Text)
import Sarutahiko.Effect.TaskQueue (TaskId (..))

-- | Pure inert resource requirements needed for static over-approximation.
--
-- Guaranteed to perform zero IO or live acquisition during Pass 1 analysis.
data ResourceDescriptor
  = GitWorktreeResource !FilePath !Text
  -- ^ Isolated git worktree directory and branch/ref.
  | CompilerToolchain !Text
  -- ^ Required compiler version (e.g. "ghc-9.12.2").
  | SandboxPolicy !Text
  -- ^ Sandbox isolation profile (e.g. "bwrap-isolated").
  | ComputeBudget !Int
  -- ^ Maximum timeout in seconds or token execution budget.
  deriving stock (Eq, Ord, Show)

-- | Strict set over-approximation of all resources required across all branches.
newtype VirtualTree = VirtualTree
  { virtualResources :: Set ResourceDescriptor }
  deriving stock (Eq, Ord, Show)
  deriving newtype (Semigroup, Monoid)

-- | Specification workflow tree node.
data SpecNode
  = AtomicSpec !TaskId !Text ![ResourceDescriptor] !(Maybe Text)
  -- ^ Primitive leaf specification with identifier, description, resources, and optional verification command.
  | ParallelSpecs ![SpecNode]
  -- ^ Concurrently scheduled composite.
  | SequentialSpecs ![SpecNode]
  -- ^ Sequentially scheduled composite.
  | ConditionalSpec !Text !SpecNode !SpecNode
  -- ^ Branch with condition description, then-branch, and else-branch.
  deriving stock (Eq, Ord, Show)

-- | Top-level task specification envelope.
data TaskSpec = TaskSpec
  { specId          :: !TaskId
  , specTitle       :: !Text
  , specDescription :: !Text
  , specRoot        :: !SpecNode
  } deriving stock (Eq, Ord, Show)

-- | Fully decomposed atomic leaf task packet.
data AtomicTask = AtomicTask
  { atomicId          :: !TaskId
  , atomicTitle       :: !Text
  , atomicDescription :: !Text
  , atomicResources   :: ![ResourceDescriptor]
  , atomicVerify      :: !(Maybe Text)
  } deriving stock (Eq, Ord, Show)

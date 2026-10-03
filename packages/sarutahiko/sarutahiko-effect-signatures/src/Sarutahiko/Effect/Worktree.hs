{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.Worktree
-- Description : Isolated git worktree and sandbox filesystem effect
--
-- Neutral GADT effect for provisioning, checkout, and teardown of isolated
-- git worktrees per EFFECT_CATALOG_DESIGN.md and YAMAARASHI_DESIGN.md §4.
module Sarutahiko.Effect.Worktree
  ( WorktreeSpec (..)
  , Worktree (..)
  ) where

import Data.Kind (Type)
import Data.Text (Text)

-- | Specification for provisioning an isolated git worktree.
data WorktreeSpec = WorktreeSpec
  { worktreeRepoPath :: !FilePath
  , worktreeRef      :: !Text
  , worktreePrefix   :: !FilePath
  } deriving stock (Eq, Ord, Show)

-- | Neutral Worktree GADT effect signature.
data Worktree (m :: Type -> Type) :: Type -> Type where
  CreateWorktree :: !WorktreeSpec -> Worktree m FilePath
  RemoveWorktree :: !FilePath     -> Worktree m ()

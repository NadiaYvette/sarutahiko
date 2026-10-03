{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : Yamaarashi.Flow.Capability
-- Description : Tagless capability classes under the Façade Pattern
--
-- Exposes monad-neutral capability typeclasses for isolated worktrees and task
-- queue leasing per YAMAARASHI_DESIGN.md §4 and DECISION-002.
module Yamaarashi.Flow.Capability
  ( -- * Re-exports from Effect Signatures
    WorktreeSpec (..)
  , TaskId (..)
  , WorkerId (..)
  , TaskPacket (..)
  , TaskResult (..)
    -- * Tagless Capability Typeclasses
  , MonadWorktree (..)
  , MonadTaskQueue (..)
  ) where

import Data.Text ()
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskResult (..), WorkerId (..))
import Sarutahiko.Effect.Worktree (WorktreeSpec (..))

-- | Capability typeclass for isolated worktree lifecycle management.
class Monad m => MonadWorktree m where
  withWorktree :: WorktreeSpec -> (FilePath -> m a) -> m a

-- | Capability typeclass for claiming and completing tasks in a queue.
class Monad m => MonadTaskQueue m where
  claimTask    :: WorkerId -> m (Maybe TaskPacket)
  completeTask :: TaskId -> TaskResult -> m ()

instance MonadWorktree IO where
  withWorktree spec k = k (worktreePrefix spec)

instance MonadTaskQueue IO where
  claimTask _ = pure Nothing
  completeTask _ _ = pure ()

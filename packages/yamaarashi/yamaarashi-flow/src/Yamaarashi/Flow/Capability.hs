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
  , SessionId (..)
  , EventId (..)
  , StoredEvent (..)
    -- * Tagless Capability Typeclasses
  , MonadWorktree (..)
  , MonadTaskQueue (..)
  , MonadEventStore (..)
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Sarutahiko.Effect.EventStore (EventId (..), SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskResult (..), WorkerId (..))
import Sarutahiko.Effect.Worktree (WorktreeSpec (..))

-- | Capability typeclass for isolated worktree lifecycle management.
class Monad m => MonadWorktree m where
  withWorktree :: WorktreeSpec -> (FilePath -> m a) -> m a

-- | Capability typeclass for claiming, leasing, and completing tasks in a queue.
class Monad m => MonadTaskQueue m where
  enqueueTask  :: TaskId -> TaskPacket -> m ()
  claimTask    :: WorkerId -> m (Maybe TaskPacket)
  completeTask :: TaskId -> TaskResult -> m ()
  failTask     :: TaskId -> Text -> m ()

-- | Capability typeclass for appending and querying events in an event store.
class Monad m => MonadEventStore m where
  appendEvent  :: SessionId -> Text -> ByteString -> m EventId
  readEvents   :: SessionId -> m [StoredEvent]

instance MonadWorktree IO where
  withWorktree spec k = k (worktreePrefix spec)

instance MonadTaskQueue IO where
  enqueueTask _ _ = pure ()
  claimTask _ = pure Nothing
  completeTask _ _ = pure ()
  failTask _ _ = pure ()

instance MonadEventStore IO where
  appendEvent _ _ _ = pure (EventId 0)
  readEvents _ = pure []

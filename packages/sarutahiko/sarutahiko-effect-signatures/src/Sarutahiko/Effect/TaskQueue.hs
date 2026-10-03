{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.TaskQueue
-- Description : Neutral task queue operations and atomic leasing
--
-- Neutral GADT effect for claiming, dispatching, and completing tasks
-- per EFFECT_CATALOG_DESIGN.md and AGENTIC_TASK_MANAGEMENT_DESIGN.md.
module Sarutahiko.Effect.TaskQueue
  ( TaskId (..)
  , WorkerId (..)
  , TaskPacket (..)
  , TaskResult (..)
  , TaskQueue (..)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)

-- | Unique task identifier.
newtype TaskId = TaskId { unTaskId :: Text }
  deriving stock (Eq, Ord, Show)

-- | Worker or agent identity holding task leases.
newtype WorkerId = WorkerId { unWorkerId :: Text }
  deriving stock (Eq, Ord, Show)

-- | Encoded task payload.
newtype TaskPacket = TaskPacket { unTaskPacket :: ByteString }
  deriving stock (Eq, Ord, Show)

-- | Result of a completed task execution.
data TaskResult
  = TaskSuccess !ByteString
  | TaskFailure !Text
  deriving stock (Eq, Ord, Show)

-- | Neutral TaskQueue GADT effect signature.
data TaskQueue (m :: Type -> Type) :: Type -> Type where
  EnqueueTask  :: !TaskId -> !TaskPacket -> TaskQueue m ()
  ClaimTask    :: !WorkerId -> TaskQueue m (Maybe TaskPacket)
  CompleteTask :: !TaskId -> !TaskResult -> TaskQueue m ()
  FailTask     :: !TaskId -> !Text -> TaskQueue m ()

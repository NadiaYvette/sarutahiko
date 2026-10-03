{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.EventStore
-- Description : Neutral event store operations
--
-- Neutral GADT effect for appending and querying large-anon event records
-- per EFFECT_CATALOG_DESIGN.md and AGENTIC_TASK_MANAGEMENT_DESIGN.md.
module Sarutahiko.Effect.EventStore
  ( SessionId (..)
  , EventId (..)
  , StoredEvent (..)
  , EventStore (..)
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Text (Text)

-- | Unique session or stream identifier.
newtype SessionId = SessionId { unSessionId :: Text }
  deriving stock (Eq, Ord, Show)

-- | Event sequence identifier.
newtype EventId = EventId { unEventId :: Int64 }
  deriving stock (Eq, Ord, Show)

-- | Neutral stored event row.
data StoredEvent = StoredEvent
  { eventId        :: !Int64
  , eventSessionId :: !Text
  , eventType      :: !Text
  , eventPayload   :: !ByteString
  , eventCreatedAt :: !Text
  } deriving stock (Eq, Show)

-- | Neutral EventStore GADT effect signature.
data EventStore (m :: Type -> Type) :: Type -> Type where
  AppendEvent :: !SessionId -> !Text -> !ByteString -> EventStore m EventId
  ReadEvents  :: !SessionId -> EventStore m [StoredEvent]

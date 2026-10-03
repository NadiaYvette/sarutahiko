{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Sarutahiko.Effect.ModelAPI
-- Description : Neutral ModelAPI GADT signature and row types
--
-- Neutral GADT effect for LLM completions, element streaming, embeddings,
-- and token counting per LLM_SUBSTRATE_DESIGN.md and EFFECT_CATALOG_DESIGN.md.
module Sarutahiko.Effect.ModelAPI
  ( -- * Roles & Messages
    Role (..)
  , Message (..)

    -- * Tool Calling
  , ToolDefinition (..)
  , ToolCall (..)
  , ToolCallDelta (..)

    -- * Options & Requirements
  , ModelOptions (..)
  , defaultModelOptions
  , CompletionReq (..)

    -- * Stop Reasons & Usage Monoid (L2)
  , StopReason (..)
  , Usage (..)

    -- * Responses & Stream Events (L1)
  , CompletionResp (..)
  , StreamEvent (..)

    -- * Embeddings & Token Accounting
  , EmbedReq (..)
  , EmbedResp (..)
  , TokenCount (..)

    -- * The ModelAPI GADT
  , ModelAPI (..)
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import GHC.Generics (Generic)

import Sarutahiko.Effect.Stepper (Stepper)

-- | Conversational role.
data Role
  = RoleSystem
  | RoleUser
  | RoleAssistant
  | RoleTool
  deriving stock (Eq, Ord, Show, Generic)

-- | A single conversational message.
data Message = Message
  { msgRole    :: !Role
  , msgContent :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Tool definition descriptor.
data ToolDefinition = ToolDefinition
  { toolName        :: !Text
  , toolDescription :: !Text
  , toolSchema      :: !ByteString
  } deriving stock (Eq, Show, Generic)

-- | Reified tool call emitted by an LLM.
data ToolCall = ToolCall
  { callId        :: !Text
  , callName      :: !Text
  , callArguments :: !ByteString
  } deriving stock (Eq, Show, Generic)

-- | Incremental tool call chunk in streaming mode.
data ToolCallDelta = ToolCallDelta
  { deltaIndex :: !Int
  , deltaId    :: !(Maybe Text)
  , deltaName  :: !(Maybe Text)
  , deltaArgs  :: !ByteString
  } deriving stock (Eq, Show, Generic)

-- | Model generation options.
data ModelOptions = ModelOptions
  { optTemperature    :: !(Maybe Double)
  , optMaxTokens      :: !(Maybe Int)
  , optThinking       :: !(Maybe Int)
  , optCacheRetention :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | Default generation options.
defaultModelOptions :: ModelOptions
defaultModelOptions = ModelOptions
  { optTemperature    = Nothing
  , optMaxTokens      = Nothing
  , optThinking       = Nothing
  , optCacheRetention = False
  }

-- | Completion request.
data CompletionReq = CompletionReq
  { reqModel    :: !Text
  , reqMessages :: ![Message]
  , reqTools    :: ![ToolDefinition]
  , reqOptions  :: !ModelOptions
  } deriving stock (Eq, Show, Generic)

-- | Reason for model completion termination (L1).
data StopReason
  = StopCompleted
  | StopMaxTokens
  | StopToolUse
  | StopCancelled
  | StopError !Text
  deriving stock (Eq, Show, Generic)

-- | Disjoint token usage accounting satisfying the Monoid laws (L2).
data Usage = Usage
  { usageInputTokens      :: !Int
  , usageOutputTokens     :: !Int
  , usageCacheReadTokens  :: !Int
  , usageCacheWriteTokens :: !Int
  , usageReasoningTokens  :: !Int
  } deriving stock (Eq, Show, Generic)

instance Semigroup Usage where
  Usage i1 o1 cr1 cw1 r1 <> Usage i2 o2 cr2 cw2 r2 =
    Usage (i1 + i2) (o1 + o2) (cr1 + cr2) (cw1 + cw2) (r1 + r2)

instance Monoid Usage where
  mempty = Usage 0 0 0 0 0

-- | Full completion response.
data CompletionResp = CompletionResp
  { respContent    :: !Text
  , respToolCalls  :: ![ToolCall]
  , respStopReason :: !StopReason
  , respUsage      :: !Usage
  } deriving stock (Eq, Show, Generic)

-- | Canonical streaming event emitted during generation (L1).
data StreamEvent
  = EventStart
  | TextDelta !Text
  | ToolDelta !ToolCallDelta
  | EventDone !Usage !StopReason
  | EventError !Text
  deriving stock (Eq, Show, Generic)

-- | Vector embedding request.
data EmbedReq = EmbedReq
  { embedModel :: !Text
  , embedTexts :: ![Text]
  } deriving stock (Eq, Show, Generic)

-- | Vector embedding response.
data EmbedResp = EmbedResp
  { embedVectors :: ![[Double]]
  , embedUsage   :: !Usage
  } deriving stock (Eq, Show, Generic)

-- | Budget accounting token count.
newtype TokenCount = TokenCount { unTokenCount :: Int }
  deriving stock (Eq, Ord, Show)

-- | Neutral ModelAPI GADT effect signature per EFFECT_CATALOG_DESIGN.md.
data ModelAPI (m :: Type -> Type) :: Type -> Type where
  Complete :: !CompletionReq -> ModelAPI m CompletionResp
  Stream   :: !CompletionReq -> ModelAPI m (Stepper m StreamEvent)
  Embed    :: !EmbedReq      -> ModelAPI m EmbedResp
  Count    :: ![Message]     -> ModelAPI m TokenCount

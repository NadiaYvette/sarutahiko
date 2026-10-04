{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Gateway.Types
-- Description : Core domain models and platform identifiers for the chat gateway
--
-- Represents chat platforms (Telegram, Discord, Slack, HTTP Webhooks),
-- incoming/outgoing gateway messages, and lifecycle events.
module Sarutahiko.Gateway.Types
  ( -- * Platform Identifiers
    Platform (..)
  , platformName
    -- * Message Payloads
  , GatewayMessage (..)
    -- * Lifecycle & Network Events
  , GatewayEvent (..)
    -- * Configuration
  , GatewayConfig (..)
  , defaultGatewayConfig
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Target messaging or social platform.
data Platform
  = Telegram
  | Discord
  | Slack
  | Webhook
  | CustomPlatform !Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Canonical text representation of a platform.
platformName :: Platform -> Text
platformName Telegram           = "telegram"
platformName Discord            = "discord"
platformName Slack              = "slack"
platformName Webhook            = "webhook"
platformName (CustomPlatform p) = p

-- | Normalized message envelope routed through the gateway.
data GatewayMessage = GatewayMessage
  { gmMessageId   :: !Text
  , gmPlatform    :: !Platform
  , gmSenderId    :: !Text
  , gmRecipientId :: !Text
  , gmContent     :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Discrete event emitted by gateway transports.
data GatewayEvent
  = EvMessageReceived !GatewayMessage
  | EvConnectionOpened !Platform !Text
  | EvConnectionClosed !Platform !Text
  deriving stock (Eq, Show, Generic)

-- | Static gateway configuration.
data GatewayConfig = GatewayConfig
  { gcEnabledPlatforms :: ![Platform]
  , gcWebhookSecret    :: !(Maybe Text)
  , gcPollIntervalMs   :: !Int
  } deriving stock (Eq, Show, Generic)

-- | Default config enabling webhooks with 100ms polling.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { gcEnabledPlatforms = [Webhook, Telegram, Discord, Slack]
  , gcWebhookSecret    = Nothing
  , gcPollIntervalMs   = 100
  }

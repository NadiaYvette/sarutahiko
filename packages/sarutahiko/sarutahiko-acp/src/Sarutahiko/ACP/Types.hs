{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.ACP.Types
-- Description : Core protocol types for the Agent Client Protocol (ACP)
--
-- Represents ACP initialization handshakes, session parameters, prompt turns,
-- and tool calling for editor integrations (e.g. Zed).
module Sarutahiko.ACP.Types
  ( -- * Protocol Version
    acpProtocolVersion
    -- * Client & Server Info
  , AcpClientInfo (..)
  , AcpServerInfo (..)
  , defaultServerInfo
    -- * Capabilities
  , AcpCapabilities (..)
  , defaultCapabilities
    -- * Handshake
  , AcpInitializeResult (..)
    -- * Sessions & Prompts
  , AcpSession (..)
  , AcpPromptParams (..)
  , AcpPromptResult (..)
    -- * Tools
  , AcpToolCall (..)
  , AcpToolResult (..)
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Current supported ACP protocol version.
acpProtocolVersion :: Text
acpProtocolVersion = "2024-11-05"

-- | Information about the connected editor client.
data AcpClientInfo = AcpClientInfo
  { clientName    :: !Text
  , clientVersion :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Information about the Sarutahiko ACP server.
data AcpServerInfo = AcpServerInfo
  { serverName    :: !Text
  , serverVersion :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Canonical server information.
defaultServerInfo :: AcpServerInfo
defaultServerInfo = AcpServerInfo
  { serverName    = "sarutahiko-acp"
  , serverVersion = "0.1.0.0"
  }

-- | Negotiated capabilities between editor and agent.
data AcpCapabilities = AcpCapabilities
  { capTools     :: !Bool
  , capStreaming :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | Default server capabilities.
defaultCapabilities :: AcpCapabilities
defaultCapabilities = AcpCapabilities
  { capTools     = True
  , capStreaming = True
  }

-- | Response payload for 'initialize' request.
data AcpInitializeResult = AcpInitializeResult
  { initProtocolVersion :: !Text
  , initServerInfo      :: !AcpServerInfo
  , initCapabilities    :: !AcpCapabilities
  } deriving stock (Eq, Show, Generic)

-- | Active editor session representation.
data AcpSession = AcpSession
  { sessId     :: !Text
  , sessWorkDir:: !Text
  , sessModel  :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Parameters for a prompt turn.
data AcpPromptParams = AcpPromptParams
  { promptSessionId :: !Text
  , promptText      :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Final result of a prompt turn.
data AcpPromptResult = AcpPromptResult
  { resSessionId :: !Text
  , resText      :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Tool call requested by the agent or forwarded to editor.
data AcpToolCall = AcpToolCall
  { toolCallId   :: !Text
  , toolCallName :: !Text
  , toolCallArgs :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Execution result of a tool call.
data AcpToolResult = AcpToolResult
  { toolResId    :: !Text
  , toolResText  :: !Text
  , toolResError :: !Bool
  } deriving stock (Eq, Show, Generic)

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Agent.Registry
-- Description : Dynamic tool, command, and skill registry
--
-- Manages tool discovery, registration, and schema extraction for LLM tool-calling
-- per NIH_PLAN.md Tier 2 (sarutahiko-agent).
module Sarutahiko.Agent.Registry
  ( -- * Registered Tool Model
    RegisteredTool (..)
  , ToolRegistry (..)
  , emptyRegistry
  , registerToolDef
  , lookupTool
  , toToolDefinitions

    -- * Built-in Standard Tools
  , defaultAgentRegistry
  , makeEchoTool
  ) where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Sarutahiko.Effect.ModelAPI (ToolDefinition (..))
import Sarutahiko.Plugins.Types (CapabilityGrant)

-- | Definition and runtime handler for an agent tool.
data RegisteredTool = RegisteredTool
  { rtName                 :: !Text
  , rtDescription          :: !Text
  , rtSchema               :: !ByteString
  , rtHandler              :: !(ByteString -> IO (Text, Bool))
  , rtRequiredCapabilities :: ![CapabilityGrant]
  }

-- | Registry collection of available tools.
newtype ToolRegistry = ToolRegistry
  { unToolRegistry :: Map Text RegisteredTool
  }

-- | Empty tool registry.
emptyRegistry :: ToolRegistry
emptyRegistry = ToolRegistry Map.empty

-- | Register a tool definition.
registerToolDef :: RegisteredTool -> ToolRegistry -> ToolRegistry
registerToolDef t (ToolRegistry m) = ToolRegistry (Map.insert (rtName t) t m)

-- | Lookup a tool by name.
lookupTool :: Text -> ToolRegistry -> Maybe RegisteredTool
lookupTool name (ToolRegistry m) = Map.lookup name m

-- | Convert registry into 'ToolDefinition' list for ModelAPI completion requests.
toToolDefinitions :: ToolRegistry -> [ToolDefinition]
toToolDefinitions (ToolRegistry m) =
  [ ToolDefinition (rtName t) (rtDescription t) (rtSchema t)
  | t <- Map.elems m
  ]

-- ----------------------------------------------------------------------------
-- Standard Built-in Tools
-- ----------------------------------------------------------------------------

-- | Construct a standard in-memory echo tool.
makeEchoTool :: RegisteredTool
makeEchoTool = RegisteredTool
  { rtName                 = "echo"
  , rtDescription          = "Echoes the provided input argument"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"input\":{\"type\":\"string\"}},\"required\":[\"input\"]}"
  , rtHandler              = \args -> pure ("echo: " <> TE.decodeUtf8 args, True)
  , rtRequiredCapabilities = []
  }

-- | Default agent tool registry.
defaultAgentRegistry :: ToolRegistry
defaultAgentRegistry = registerToolDef makeEchoTool emptyRegistry

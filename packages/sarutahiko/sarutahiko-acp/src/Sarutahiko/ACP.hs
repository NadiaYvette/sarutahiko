-- |
-- Module      : Sarutahiko.ACP
-- Description : Agent Client Protocol (ACP) adapter for editor integration
--
-- Implements the Agent Client Protocol over JSON-RPC 2.0 stdio framing,
-- enabling Zed and other editors to drive Sarutahiko agent sessions.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts
-- pioneered by:
-- * Agent Client Protocol (Zed Industries) — editor-agent JSON-RPC communication
-- * Model Context Protocol (Anthropic) — capability negotiation and tool dispatch
-- * Hermes Agent (Nous Research) — narrow-waist agent execution interfaces
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.ACP
  ( module Sarutahiko.ACP.Types
  , module Sarutahiko.ACP.Protocol
  , module Sarutahiko.ACP.Server
  ) where

import Sarutahiko.ACP.Protocol
import Sarutahiko.ACP.Server
import Sarutahiko.ACP.Types

-- |
-- Module      : Sarutahiko.MCP
-- Description : Top-level Model Context Protocol (MCP 2025-03-26) entrypoint
--
-- Re-exports the core types, server implementation with StateGuard enforcement,
-- and client request/response helpers.
module Sarutahiko.MCP
  ( -- * Core Types & Codecs
    module Sarutahiko.MCP.Types

    -- * Protocol Server
  , module Sarutahiko.MCP.Server

    -- * Protocol Client
  , module Sarutahiko.MCP.Client
  ) where

import Sarutahiko.MCP.Client
import Sarutahiko.MCP.Server
import Sarutahiko.MCP.Types

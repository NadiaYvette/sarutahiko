-- |
-- Module      : Sarutahiko.JsonRpc
-- Description : Spec-conformant row-directed JSON-RPC 2.0 engine
--
-- Re-exports the core types, errors, and dispatch engine for JSON-RPC 2.0.
--
-- === Intellectual Lineage & Attribution
-- This module implements the JSON-RPC 2.0 specification, drawing architectural guidance from:
-- * 'haskell-lsp' (Alan Zimmerman et al.) — protocol message routing
-- * 'mono-traversable' (Michael Snoyman) — NonNull non-emptiness guarantees on batch envelopes
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.JsonRpc
  ( -- * Core Types
    module Sarutahiko.JsonRpc.Types

    -- * Error Taxonomy
  , module Sarutahiko.JsonRpc.Error

    -- * Framing & Dispatch Engine
  , module Sarutahiko.JsonRpc.Dispatch
  ) where

import Sarutahiko.JsonRpc.Dispatch
import Sarutahiko.JsonRpc.Error
import Sarutahiko.JsonRpc.Types

-- |
-- Module      : Sarutahiko.JsonRpc
-- Description : Spec-conformant row-directed JSON-RPC 2.0 engine
--
-- Re-exports the core types, errors, and dispatch engine for JSON-RPC 2.0.
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

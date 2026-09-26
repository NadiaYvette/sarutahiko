{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.JsonRpc.Error
-- Description : Standard JSON-RPC 2.0 error taxonomy and constructors
--
-- Implements Invariant 1 (Standard Error Bounds):
-- Predefined JSON-RPC error codes strictly adhere to the specification:
-- - ParseError: -32700
-- - InvalidRequest: -32600
-- - MethodNotFound: -32601
-- - InvalidParams: -32602
-- - InternalError: -32603
module Sarutahiko.JsonRpc.Error
  ( -- * Predefined Error Constructors
    errParseError
  , errInvalidRequest
  , errMethodNotFound
  , errInvalidParams
  , errInternalError
  , errServerNotInitialized

    -- * Error Code Constants
  , codeParseError
  , codeInvalidRequest
  , codeMethodNotFound
  , codeInvalidParams
  , codeInternalError
  , codeServerNotInitialized
  ) where

import Data.Text (Text)
import Sarutahiko.JsonRpc.Types (JsonRpcError (..))

-- | Invalid JSON was received by the server (-32700).
codeParseError :: Int
codeParseError = -32700

-- | The JSON sent is not a valid Request object (-32600).
codeInvalidRequest :: Int
codeInvalidRequest = -32600

-- | The method does not exist / is not available (-32601).
codeMethodNotFound :: Int
codeMethodNotFound = -32601

-- | Invalid method parameter(s) (-32602).
codeInvalidParams :: Int
codeInvalidParams = -32602

-- | Internal JSON-RPC error (-32603).
codeInternalError :: Int
codeInternalError = -32603

-- | Server has not yet completed handshake initialization (-32600).
codeServerNotInitialized :: Int
codeServerNotInitialized = -32600

-- | Constructor for ParseError (-32700).
errParseError :: Text -> JsonRpcError
errParseError msg = JsonRpcError codeParseError msg Nothing

-- | Constructor for InvalidRequest (-32600).
errInvalidRequest :: Text -> JsonRpcError
errInvalidRequest msg = JsonRpcError codeInvalidRequest msg Nothing

-- | Constructor for MethodNotFound (-32601).
errMethodNotFound :: Text -> JsonRpcError
errMethodNotFound method =
  JsonRpcError codeMethodNotFound ("Method not found: " <> method) Nothing

-- | Constructor for InvalidParams (-32602).
errInvalidParams :: Text -> JsonRpcError
errInvalidParams msg = JsonRpcError codeInvalidParams msg Nothing

-- | Constructor for InternalError (-32603).
errInternalError :: Text -> JsonRpcError
errInternalError msg = JsonRpcError codeInternalError msg Nothing

-- | Constructor for ServerNotInitialized (-32600).
errServerNotInitialized :: Text -> JsonRpcError
errServerNotInitialized msg = JsonRpcError codeServerNotInitialized msg Nothing

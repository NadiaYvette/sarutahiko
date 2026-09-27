{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.MCP.Client
-- Description : MCP 2025-03-26 client protocol engine
--
-- Implements Task Packet TP-1.5: client engine for initiating MCP handshakes,
-- discovering tools via @tools/list@, and invoking tools via @tools/call@.
module Sarutahiko.MCP.Client
  ( -- * Client Types
    McpClient (..)
  , newMcpClient

    -- * Client Operations
  , formatInitializeRequest
  , formatInitializedNotification
  , formatListToolsRequest
  , formatCallToolRequest

    -- * Response Parsers
  , parseInitializeResponse
  , parseListToolsResponse
  , parseCallToolResponse
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T

import Kogaki.Wire.Json.Decode (extractObjectFields, renderTokens)
import Kogaki.Wire.Json.Lexer (lexJsonEither)
import Sarutahiko.JsonRpc.Types (JsonRpcId (..), encodeJsonRpcId)
import Sarutahiko.MCP.Types
  ( CallToolParams (..)
  , CallToolResult (..)
  , Implementation (..)
  , InitializeParams (..)
  , InitializeResult (..)
  , ListToolsResult (..)
  , defaultClientCapabilities
  , decodeCallToolResult
  , decodeInitializeResult
  , decodeListToolsResult
  , encodeCallToolParams
  , encodeInitializeParams
  , mcpVersion2025_03_26
  )

-- | State of an active MCP client connection.
data McpClient = McpClient
  { mcClientInfo :: !Implementation
  , mcNextReqId  :: !(MVar Int64)
  }

-- | Create a new client handle with an initialized request sequence.
newMcpClient :: Implementation -> IO McpClient
newMcpClient clientInfo = do
  reqIdVar <- newMVar 1
  pure (McpClient clientInfo reqIdVar)

-- | Get next sequential request id.
nextId :: McpClient -> IO JsonRpcId
nextId client = modifyMVar (mcNextReqId client) $ \cur ->
  pure (cur + 1, IdInt cur)

-- | Format the initial @initialize@ request frame.
formatInitializeRequest :: McpClient -> IO (JsonRpcId, ByteString)
formatInitializeRequest client = do
  reqId <- nextId client
  let params = InitializeParams
        { ipProtocolVersion = mcpVersion2025_03_26
        , ipCapabilities     = defaultClientCapabilities
        , ipClientInfo       = mcClientInfo client
        }
      paramsBytes = encodeInitializeParams params
      payload =
        "{\"id\":" <> encodeJsonRpcId reqId <>
        ",\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":" <> paramsBytes <> "}"
  pure (reqId, payload)

-- | Format the post-handshake @notifications/initialized@ frame.
formatInitializedNotification :: ByteString
formatInitializedNotification =
  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"

-- | Format a @tools/list@ request frame.
formatListToolsRequest :: McpClient -> IO (JsonRpcId, ByteString)
formatListToolsRequest client = do
  reqId <- nextId client
  let payload =
        "{\"id\":" <> encodeJsonRpcId reqId <>
        ",\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"params\":{}}"
  pure (reqId, payload)

-- | Format a @tools/call@ request frame.
formatCallToolRequest :: McpClient -> Text -> Maybe ByteString -> IO (JsonRpcId, ByteString)
formatCallToolRequest client tName mArgs = do
  reqId <- nextId client
  let params = CallToolParams
        { ctpName      = tName
        , ctpArguments = mArgs
        }
      paramsBytes = encodeCallToolParams params
      payload =
        "{\"id\":" <> encodeJsonRpcId reqId <>
        ",\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":" <> paramsBytes <> "}"
  pure (reqId, payload)

-- | Parse the response of an @initialize@ request.
parseInitializeResponse :: ByteString -> Either Text InitializeResult
parseInitializeResponse bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  case Map.lookup "error" fields of
    Just errToks -> Left ("JSON-RPC Error: " <> T.pack (show errToks))
    Nothing -> do
      resToks <- maybe (Left "Missing 'result' in initialize response") Right (Map.lookup "result" fields)
      decodeInitializeResult (renderTokens resToks)

-- | Parse the response of a @tools/list@ request.
parseListToolsResponse :: ByteString -> Either Text ListToolsResult
parseListToolsResponse bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  case Map.lookup "error" fields of
    Just errToks -> Left ("JSON-RPC Error: " <> T.pack (show errToks))
    Nothing -> do
      resToks <- maybe (Left "Missing 'result' in tools/list response") Right (Map.lookup "result" fields)
      decodeListToolsResult (renderTokens resToks)

-- | Parse the response of a @tools/call@ request.
parseCallToolResponse :: ByteString -> Either Text CallToolResult
parseCallToolResponse bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  case Map.lookup "error" fields of
    Just errToks -> Left ("JSON-RPC Error: " <> T.pack (show errToks))
    Nothing -> do
      resToks <- maybe (Left "Missing 'result' in tools/call response") Right (Map.lookup "result" fields)
      decodeCallToolResult (renderTokens resToks)

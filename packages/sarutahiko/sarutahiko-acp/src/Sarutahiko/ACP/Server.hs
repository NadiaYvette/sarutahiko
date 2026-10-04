{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.ACP.Server
-- Description : In-process JSON-RPC dispatcher for Agent Client Protocol
--
-- Routes incoming ACP requests (handshake, prompt turn, tool calls)
-- and returns spec-conformant JSON-RPC responses.
module Sarutahiko.ACP.Server
  ( dispatchAcpPayload
  , handleAcpRequest
  ) where

import Data.ByteString (ByteString)
import Data.NonNull (toNullable)

import Sarutahiko.ACP.Protocol
import Sarutahiko.ACP.Types
import Sarutahiko.JsonRpc.Dispatch
  ( parseRawRequests
  )
import Sarutahiko.JsonRpc.Error
  ( errInvalidParams
  , errMethodNotFound
  )
import Sarutahiko.JsonRpc.Types
  ( JsonRpcError
  , JsonRpcId (..)
  , RawJsonRpcRequest (..)
  , encodeJsonRpcError
  , encodeJsonRpcId
  )

-- | Dispatch an incoming ACP JSON-RPC payload and produce a response.
dispatchAcpPayload :: ByteString -> IO ByteString
dispatchAcpPayload bs = case parseRawRequests bs of
  Left err -> pure (formatError Nothing err)
  Right (_, []) -> pure ""
  Right (_, Left (mId, err) : _) -> pure (formatError mId err)
  Right (_, Right req : _) -> do
    mResp <- handleAcpRequest req
    case mResp of
      Left err -> pure (formatError (rawReqId req) err)
      Right ok -> pure (formatResponse (rawReqId req) ok)

-- | Format a successful JSON-RPC 2.0 response.
formatResponse :: Maybe JsonRpcId -> ByteString -> ByteString
formatResponse mId resultBytes =
  let idPart = maybe "null" encodeJsonRpcId mId
  in "{\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\",\"result\":" <> resultBytes <> "}"

-- | Format a JSON-RPC 2.0 error response.
formatError :: Maybe JsonRpcId -> JsonRpcError -> ByteString
formatError mId err =
  let idPart = maybe "null" encodeJsonRpcId mId
  in "{\"error\":" <> encodeJsonRpcError err <> ",\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\"}"

-- | Process a single raw ACP request.
handleAcpRequest :: RawJsonRpcRequest -> IO (Either JsonRpcError ByteString)
handleAcpRequest req =
  let method = toNullable (rawReqMethod req)
  in case method of
    "initialize" -> do
      let initRes = AcpInitializeResult
            { initProtocolVersion = acpProtocolVersion
            , initServerInfo      = defaultServerInfo
            , initCapabilities    = defaultCapabilities
            }
      pure (Right (encodeInitializeResult initRes))

    "session/prompt" -> case rawReqParams req of
      Nothing -> pure (Left (errInvalidParams "Missing params for session/prompt"))
      Just pBs -> case parsePromptParams pBs of
        Nothing -> pure (Left (errInvalidParams "Malformed params for session/prompt"))
        Just p  -> do
          let resp = AcpPromptResult
                { resSessionId = promptSessionId p
                , resText      = "ACP echo: " <> promptText p
                }
          pure (Right (encodePromptResult resp))

    "tools/call" -> case rawReqParams req of
      Nothing -> pure (Left (errInvalidParams "Missing params for tools/call"))
      Just pBs -> case parseToolCallParams pBs of
        Nothing -> pure (Left (errInvalidParams "Malformed params for tools/call"))
        Just tc -> do
          let res = AcpToolResult
                { toolResId    = toolCallId tc
                , toolResText  = "Executed tool " <> toolCallName tc <> " with args: " <> toolCallArgs tc
                , toolResError = False
                }
          pure (Right (encodeToolResult res))

    unknown ->
      pure (Left (errMethodNotFound unknown))

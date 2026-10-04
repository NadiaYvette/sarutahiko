{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.ACP.Protocol
-- Description : Zero-Aeson wire codecs and JSON-RPC formatting for ACP
--
-- Serializes and deserializes ACP handshake, prompt turns, and tool results
-- without transitive JSON bloat.
module Sarutahiko.ACP.Protocol
  ( encodeInitializeResult
  , encodePromptResult
  , encodeToolResult
  , parsePromptParams
  , parseToolCallParams
  ) where

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Kogaki.Wire.Json.Decode
  ( extractObjectFields
  )
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.ACP.Types

-- | Encode 'AcpInitializeResult' into JSON.
encodeInitializeResult :: AcpInitializeResult -> ByteString
encodeInitializeResult res =
  "{\"protocolVersion\":\"" <> TE.encodeUtf8 (initProtocolVersion res)
  <> "\",\"serverInfo\":{\"name\":\"" <> TE.encodeUtf8 (serverName (initServerInfo res))
  <> "\",\"version\":\"" <> TE.encodeUtf8 (serverVersion (initServerInfo res))
  <> "\"},\"capabilities\":{\"tools\":"
  <> (if capTools (initCapabilities res) then "true" else "false")
  <> ",\"streaming\":"
  <> (if capStreaming (initCapabilities res) then "true" else "false")
  <> "}}"

-- | Encode 'AcpPromptResult' into JSON.
encodePromptResult :: AcpPromptResult -> ByteString
encodePromptResult res =
  "{\"sessionId\":\"" <> escapeJson (resSessionId res)
  <> "\",\"text\":\"" <> escapeJson (resText res)
  <> "\"}"

-- | Encode 'AcpToolResult' into JSON.
encodeToolResult :: AcpToolResult -> ByteString
encodeToolResult res =
  "{\"callId\":\"" <> escapeJson (toolResId res)
  <> "\",\"output\":\"" <> escapeJson (toolResText res)
  <> "\",\"isError\":" <> (if toolResError res then "true" else "false")
  <> "}"

-- | Parse prompt parameters from JSON bytes.
parsePromptParams :: ByteString -> Maybe AcpPromptParams
parsePromptParams bs = do
  tokens <- case lexJsonEither bs of
    Left _   -> Nothing
    Right ts -> Just ts
  fieldMap <- case extractObjectFields tokens of
    Left _  -> Nothing
    Right m -> Just m
  let lookupString key = case Map.lookup key fieldMap of
        Just [TkString s] -> Just s
        _                 -> Nothing
  sid <- lookupString "sessionId"
  prompt <- lookupString "prompt"
  pure $ AcpPromptParams
    { promptSessionId = sid
    , promptText      = prompt
    }

-- | Parse tool call parameters from JSON bytes.
parseToolCallParams :: ByteString -> Maybe AcpToolCall
parseToolCallParams bs = do
  tokens <- case lexJsonEither bs of
    Left _   -> Nothing
    Right ts -> Just ts
  fieldMap <- case extractObjectFields tokens of
    Left _  -> Nothing
    Right m -> Just m
  let lookupString key = case Map.lookup key fieldMap of
        Just [TkString s] -> Just s
        _                 -> Nothing
  cid <- lookupString "callId"
  name <- lookupString "name"
  let args = case lookupString "arguments" of
        Just a  -> a
        Nothing -> "{}"
  pure $ AcpToolCall
    { toolCallId   = cid
    , toolCallName = name
    , toolCallArgs = args
    }

-- | Helper escaping text for JSON encoding.
escapeJson :: Text -> ByteString
escapeJson txt = TE.encodeUtf8 $ T.concatMap escapeChar txt
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = T.singleton c

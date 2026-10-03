{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Utai.Wire
-- Description : Strictly zero-Aeson wire codecs for LLM protocols
--
-- Implements serialization and deserialization for OpenAI-compatible
-- Chat Completions API and SSE streaming deltas per LLM_SUBSTRATE_DESIGN.md.
module Utai.Wire
  ( -- * Encoders
    encodeChatCompletionReq
  , encodeMessage
  , encodeRole

    -- * Decoders
  , decodeChatCompletionResp
  , parseSseStreamChunk
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Kogaki.Wire.Json.Decode (extractObjectFields)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.Effect.ModelAPI

-- | Canonically encode a 'CompletionReq' to OpenAI-compatible JSON bytes.
encodeChatCompletionReq :: CompletionReq -> ByteString
encodeChatCompletionReq req =
  "{"
  <> "\"model\":\"" <> escapeJsonText (reqModel req) <> "\""
  <> ",\"messages\":[" <> BS.intercalate "," (map encodeMessage (reqMessages req)) <> "]"
  <> case optTemperature (reqOptions req) of
       Nothing -> ""
       Just t  -> ",\"temperature\":" <> BSC.pack (show t)
  <> case optMaxTokens (reqOptions req) of
       Nothing -> ""
       Just m  -> ",\"max_tokens\":" <> BSC.pack (show m)
  <> "}"

-- | Encode a single 'Message'.
encodeMessage :: Message -> ByteString
encodeMessage msg =
  "{\"role\":\"" <> encodeRole (msgRole msg) <> "\",\"content\":\"" <> escapeJsonText (msgContent msg) <> "\"}"

-- | Encode a 'Role' string.
encodeRole :: Role -> ByteString
encodeRole RoleSystem    = "system"
encodeRole RoleUser      = "user"
encodeRole RoleAssistant = "assistant"
encodeRole RoleTool      = "tool"

-- | Escape characters in 'Text' for JSON string literals.
escapeJsonText :: Text -> ByteString
escapeJsonText = TE.encodeUtf8 . T.concatMap escapeChar
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = T.singleton c

-- | Decode an OpenAI-compatible completion response JSON.
decodeChatCompletionResp :: ByteString -> Either Text CompletionResp
decodeChatCompletionResp bs = do
  tokens <- lexJsonEither bs
  obj <- extractObjectFields tokens
  content <- case Map.lookup "choices" obj of
    Just (TkArrayOpen : TkObjectOpen : rest) -> do
      choiceObj <- extractObjectFields (TkObjectOpen : rest)
      case Map.lookup "message" choiceObj of
        Just msgTokens -> do
          msgObj <- extractObjectFields msgTokens
          case Map.lookup "content" msgObj of
            Just [TkString t] -> Right t
            _                 -> Right ""
        _ -> Right ""
    _ -> Right ""

  -- Extract usage
  usage <- case Map.lookup "usage" obj of
    Just uTokens -> do
      uObj <- extractObjectFields uTokens
      let getInt k = case Map.lookup k uObj of
            Just [TkInt n] -> fromIntegral n
            _              -> 0
      Right Usage
        { usageInputTokens      = getInt "prompt_tokens"
        , usageOutputTokens     = getInt "completion_tokens"
        , usageCacheReadTokens  = 0
        , usageCacheWriteTokens = 0
        , usageReasoningTokens  = 0
        }
    Nothing -> Right mempty

  -- Extract stop reason
  stopReason <- case Map.lookup "choices" obj of
    Just (TkArrayOpen : TkObjectOpen : rest) -> do
      choiceObj <- extractObjectFields (TkObjectOpen : rest)
      case Map.lookup "finish_reason" choiceObj of
        Just [TkString "length"]     -> Right StopMaxTokens
        Just [TkString "tool_calls"] -> Right StopToolUse
        Just [TkString _]            -> Right StopCompleted
        _                            -> Right StopCompleted
    _ -> Right StopCompleted

  Right CompletionResp
    { respContent    = content
    , respToolCalls  = []
    , respStopReason = stopReason
    , respUsage      = usage
    }

-- | Parse a single SSE stream chunk payload (e.g. data: {...} or [DONE]).
parseSseStreamChunk :: ByteString -> Either Text (Maybe StreamEvent)
parseSseStreamChunk bs
  | bs == "[DONE]" || bs == "\"[DONE]\"" = Right (Just (EventDone mempty StopCompleted))
  | BS.null (BSC.strip bs) = Right Nothing
  | otherwise = do
      tokens <- lexJsonEither bs
      obj <- extractObjectFields tokens
      case Map.lookup "choices" obj of
        Just (TkArrayOpen : TkObjectOpen : rest) -> do
          choiceObj <- extractObjectFields (TkObjectOpen : rest)
          case Map.lookup "delta" choiceObj of
            Just deltaTokens -> do
              deltaObj <- extractObjectFields deltaTokens
              case Map.lookup "content" deltaObj of
                Just [TkString t] -> Right (Just (TextDelta t))
                _                 -> Right Nothing
            _ -> Right Nothing
        _ -> Right Nothing

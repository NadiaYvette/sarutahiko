{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Sarutahiko.JsonRpc.Types
-- Description : Core JSON-RPC 2.0 types and serialization
--
-- Implements Task Packet TP-1.2: types for JSON-RPC 2.0 identifiers,
-- requests, responses, and errors, integrated with 'kogaki-wire' and
-- 'sarutahiko-records'.
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'.
module Sarutahiko.JsonRpc.Types
  ( -- * Identifiers
    JsonRpcId (..)
  , encodeJsonRpcId

    -- * Requests & Responses
  , JsonRpcRequest (..)
  , JsonRpcResponse (..)
  , RawJsonRpcRequest (..)

    -- * Errors
  , JsonRpcError (..)

    -- * Encoders & Parsers
  , encodeJsonRpcRequest
  , encodeJsonRpcResponse
  , encodeJsonRpcError
  , parseJsonRpcId
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.Functor.Identity (Identity (..))
import Data.Int (Int64)
import Data.NonNull (NonNull, fromNullable, toNullable)
import Data.Record.Anon (AllFields, KnownFields)
import Data.Record.Anon.Advanced (Record)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Kogaki.Wire.Json.Decode (ToJsonField, encodeJsonRow)
import Kogaki.Wire.Json.Lexer (JsonToken (..))
import Sarutahiko.Records.Envelope (WireEnvelope (..))

-- | IsString instance for 'NonNull Text' enabling string literals with -XOverloadedStrings.
instance IsString (NonNull Text) where
  fromString s = case fromNullable (fromString s) of
    Just nn -> nn
    Nothing -> error "IsString (NonNull Text): empty string literal is invalid for NonNull"

-- | JSON-RPC 2.0 identifier. Numbers MUST NOT contain fractional parts.
--
-- @since 0.1.0.0
data JsonRpcId
  = IdInt !Int64
  | IdString !Text
  | IdNull
  deriving stock (Eq, Ord, Show, Generic)

-- | Encode a 'JsonRpcId' to its JSON wire representation.
encodeJsonRpcId :: JsonRpcId -> ByteString
encodeJsonRpcId (IdInt n)    = BSC.pack (show n)
encodeJsonRpcId (IdString s) = "\"" <> TE.encodeUtf8 s <> "\""
encodeJsonRpcId IdNull       = "null"

-- | Parse a 'JsonRpcId' from token stream.
parseJsonRpcId :: [JsonToken] -> Maybe JsonRpcId
parseJsonRpcId [TkInt n]    = Just (IdInt n)
parseJsonRpcId [TkString s] = Just (IdString s)
parseJsonRpcId [TkNull]     = Just IdNull
parseJsonRpcId _            = Nothing

-- | Strongly typed JSON-RPC request parameterized by its argument row 'r'.
-- 'reqId = Nothing' designates a notification.
--
-- @since 0.1.0.0
data JsonRpcRequest r = JsonRpcRequest
  { reqId     :: !(Maybe JsonRpcId)
  , reqMethod :: !(NonNull Text)
  , reqParams :: !(Record Identity r)
  }

-- | Raw unparsed JSON-RPC request before row-typed specialization.
--
-- @since 0.1.0.0
data RawJsonRpcRequest = RawJsonRpcRequest
  { rawReqId     :: !(Maybe JsonRpcId)
  , rawReqMethod :: !(NonNull Text)
  , rawReqParams :: !(Maybe ByteString)
  } deriving stock (Eq, Show, Generic)

-- | Strongly typed JSON-RPC response parameterized by its result row 'r'.
--
-- @since 0.1.0.0
data JsonRpcResponse r
  = JsonRpcSuccess !JsonRpcId !(Record Identity r)
  | JsonRpcFailure !(Maybe JsonRpcId) !JsonRpcError

-- | JSON-RPC 2.0 error object.
--
-- @since 0.1.0.0
data JsonRpcError = JsonRpcError
  { errCode    :: !Int
  , errMessage :: !Text
  , errData    :: !(Maybe (WireEnvelope (Record Identity '[])))
  } deriving stock (Eq, Show, Generic)

-- | Encode a 'JsonRpcRequest r' to canonical JSON bytes.
--
-- @since 0.1.0.0
encodeJsonRpcRequest
  :: (KnownFields r, AllFields r ToJsonField)
  => JsonRpcRequest r
  -> ByteString
encodeJsonRpcRequest (JsonRpcRequest mId method params) =
  let methodBytes = TE.encodeUtf8 (toNullable method)
  in case mId of
    Nothing ->
      "{\"jsonrpc\":\"2.0\",\"method\":\"" <> methodBytes <> "\",\"params\":" <> encodeJsonRow params <> "}"
    Just reqIdent ->
      "{\"id\":" <> encodeJsonRpcId reqIdent <> ",\"jsonrpc\":\"2.0\",\"method\":\"" <> methodBytes <> "\",\"params\":" <> encodeJsonRow params <> "}"

-- | Encode a 'JsonRpcResponse r' to canonical JSON bytes.
--
-- @since 0.1.0.0
encodeJsonRpcResponse
  :: (KnownFields r, AllFields r ToJsonField)
  => JsonRpcResponse r
  -> ByteString
encodeJsonRpcResponse (JsonRpcSuccess ident result) =
  "{\"id\":" <> encodeJsonRpcId ident <> ",\"jsonrpc\":\"2.0\",\"result\":" <> encodeJsonRow result <> "}"
encodeJsonRpcResponse (JsonRpcFailure mIdent err) =
  let idPart = maybe "null" encodeJsonRpcId mIdent
  in "{\"error\":" <> encodeJsonRpcError err <> ",\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\"}"

-- | Encode a 'JsonRpcError' to JSON bytes.
--
-- @since 0.1.0.0
encodeJsonRpcError :: JsonRpcError -> ByteString
encodeJsonRpcError (JsonRpcError code msg _mData) =
  "{\"code\":" <> BSC.pack (show code) <> ",\"message\":\"" <> TE.encodeUtf8 msg <> "\"}"

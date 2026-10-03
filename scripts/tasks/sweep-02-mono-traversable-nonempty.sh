#!/usr/bin/env bash
set -euo pipefail

echo "=== [sweep-02] Integrating mono-traversable for Type-Level Non-Emptiness Constraints ==="

# 1. Update REUSE_REGISTER.md to record mono-traversable §2.29
if ! grep -q "2.29 mono-traversable" docs/registers/REUSE_REGISTER.md; then
  cat <<'EOF' >> docs/registers/REUSE_REGISTER.md

### 2.29 mono-traversable (Monomorphic sequence polymorphism and NonNull guarantees) — REUSED (2026-10-03)
Michael Snoyman's `mono-traversable` library.
Provides type classes for monomorphic containers (`MonoFunctor`, `MonoFoldable`, `MonoTraversable`)
and specifically `Data.NonNull.NonNull` for type-level non-emptiness guarantees over
`ByteString`, `Text`, `Vector`, and lists.
Role: Type-level non-emptiness constraints across wire codecs (`kogaki-wire`), JSON-RPC batch
processing (`sarutahiko-jsonrpc`), and MCP protocol framing (`sarutahiko-mcp`). Replaces defensive
runtime assertions and partial sequence operations (`head`, `tail`, `init`) with compile-time
structural non-emptiness proofs, ensuring protocol compliance (e.g. JSON-RPC 2.0 §6 batch requirements)
and eliminating zero-element crashes.
Q1 passes (pure structural typing, directly aligns with the zero-partial-functions invariant);
Q2 passes (clean typeclass hierarchy and lightweight `NonNull` newtype wrapper);
Q3 passes (mature, stable, widely relied upon in high-assurance Haskell).
EOF
  echo "  [OK] Added §2.29 mono-traversable to docs/registers/REUSE_REGISTER.md"
fi

# 2. Add mono-traversable to cabal files
echo "=== Updating cabal dependencies for mono-traversable ==="

# kogaki-wire.cabal
sed -i 's/sarutahiko-records/sarutahiko-records,\n        mono-traversable >= 1.0.17/' packages/kogaki/kogaki-wire/kogaki-wire.cabal

# sarutahiko-jsonrpc.cabal
sed -i 's/sarutahiko-records/sarutahiko-records,\n        mono-traversable >= 1.0.17/' packages/sarutahiko/sarutahiko-jsonrpc/sarutahiko-jsonrpc.cabal

# sarutahiko-mcp.cabal
sed -i 's/sarutahiko-schema,/sarutahiko-schema,\n        mono-traversable >= 1.0.17,/' packages/sarutahiko/sarutahiko-mcp/sarutahiko-mcp.cabal

# 3. Update Kogaki.Wire.SSE.Parser
cat <<'EOF' > packages/kogaki/kogaki-wire/src/Kogaki/Wire/SSE/Parser.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Kogaki.Wire.SSE.Parser
-- Description : Server-Sent Events (SSE) streaming framing and round-trip parser
--
-- Implements Closure 1 (Anti-Bloat Principle) and Invariant 2
-- (SSE Round-Trip Equivalence): zero-copy, newline-delimited framing
-- for Server-Sent Events over raw byte streams without requiring heavyweight
-- web servers or framework dependencies.
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'.
module Kogaki.Wire.SSE.Parser
  ( -- * Core Event Type
    SseEvent (..)

    -- * Non-Empty Tokens & Field Labels
  , SseFieldLabel
  , mkFieldLabel
  , renderDataLine

    -- * Stream Parsing & Rendering
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (isJust)
import Data.NonNull (NonNull, fromNullable, toNullable)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)
import Text.Read (readMaybe)

-- | Non-empty byte sequence representing an SSE field label (e.g. "id", "event", "data").
type SseFieldLabel = NonNull ByteString

-- | Construct a validated non-empty SSE field label.
mkFieldLabel :: ByteString -> Maybe SseFieldLabel
mkFieldLabel = fromNullable

-- | Render a guaranteed non-empty SSE data line.
renderDataLine :: NonNull ByteString -> ByteString
renderDataLine line = "data: " <> toNullable line <> "\n"

-- | A discrete Server-Sent Event frame.
--
-- @since 0.1.0.0
data SseEvent = SseEvent
  { sseId    :: !(Maybe Text)
  , sseEvent :: !(Maybe Text)
  , sseData  :: !ByteString
  , sseRetry :: !(Maybe Int)
  } deriving stock (Eq, Show, Generic)

-- | Parse a stream of raw bytes into a list of 'SseEvent' frames according
-- to the W3C Server-Sent Events specification.
--
-- @since 0.1.0.0
parseSseStream :: ByteString -> [SseEvent]
parseSseStream input = go (splitLines input) Nothing Nothing [] Nothing
  where
    go :: [ByteString]
       -> Maybe Text
       -> Maybe Text
       -> [ByteString]
       -> Maybe Int
       -> [SseEvent]
    go [] mId mEv dataLines mRet
      -- Flush any trailing pending event at end of stream if fields were populated
      | hasEventContent mId mEv dataLines mRet =
          [mkEvent mId mEv dataLines mRet]
      | otherwise = []

    go (line : rest) mId mEv dataLines mRet
      -- Blank line: dispatch event frame
      | BS.null line =
          if hasEventContent mId mEv dataLines mRet
            then mkEvent mId mEv dataLines mRet : go rest Nothing Nothing [] Nothing
            else go rest Nothing Nothing [] Nothing

      -- Comment line: ignore
      | BSC.take 1 line == ":" =
          go rest mId mEv dataLines mRet

      -- Field line: parse field name and value
      | otherwise =
          let (field, rawVal) = BSC.break (== ':') line
              val = case BSC.uncons rawVal of
                Just (':', stripped) ->
                  case BSC.uncons stripped of
                    Just (' ', restVal) -> restVal
                    _                   -> stripped
                _ -> ""
          in case fromNullable field of
            Nothing ->
              -- Field label is empty
              go rest mId mEv dataLines mRet
            Just fieldLabel ->
              case toNullable fieldLabel of
                "id" ->
                  let !newId = Just (TE.decodeUtf8With TEE.lenientDecode val)
                  in go rest newId mEv dataLines mRet
                "event" ->
                  let !newEv = Just (TE.decodeUtf8With TEE.lenientDecode val)
                  in go rest mId newEv dataLines mRet
                "retry" ->
                  let !newRetry = readMaybe (BSC.unpack val)
                  in go rest mId mEv dataLines (newRetry <|> mRet)
                "data" ->
                  go rest mId mEv (val : dataLines) mRet
                _ ->
                  -- Unknown field names are ignored per SSE spec
                  go rest mId mEv dataLines mRet

    hasEventContent mId mEv dataLines mRet =
      isJust mId || isJust mEv || not (null dataLines) || isJust mRet

    mkEvent mId mEv dataLines mRet =
      SseEvent
        { sseId    = mId
        , sseEvent = mEv
        , sseData  = BS.intercalate "\n" (reverse dataLines)
        , sseRetry = mRet
        }

    (<|>) :: Maybe a -> Maybe a -> Maybe a
    Just x  <|> _ = Just x
    Nothing <|> y = y

-- | Split a byte stream into lines on CRLF, LF, or CR with zero partial functions.
splitLines :: ByteString -> [ByteString]
splitLines bs
  | BS.null bs = []
  | otherwise  =
      let (line, rest) = BSC.break (\c -> c == '\n' || c == '\r') bs
      in case BSC.uncons rest of
        Nothing -> [line]
        Just ('\r', afterCr) ->
          case BSC.uncons afterCr of
            Just ('\n', afterLf) -> line : splitLines afterLf
            _                    -> line : splitLines afterCr
        Just ('\n', afterLf) -> line : splitLines afterLf
        Just (_, remainder)  -> line : splitLines remainder

-- | Render a single 'SseEvent' frame to its canonical wire byte representation.
-- Guaranteed to satisfy Law Invariant 2 (SSE Round-Trip Equivalence).
--
-- @since 0.1.0.0
renderSseEvent :: SseEvent -> ByteString
renderSseEvent (SseEvent mId mEv d mRet) =
  BS.concat
    [ maybe "" (\i -> "id: " <> TE.encodeUtf8 i <> "\n") mId
    , maybe "" (\e -> "event: " <> TE.encodeUtf8 e <> "\n") mEv
    , maybe "" (\r -> "retry: " <> BSC.pack (show r) <> "\n") mRet
    , renderData d
    , "\n"
    ]
  where
    renderData bs
      | BS.null bs = "data:\n"
      | otherwise  = BS.concat [ "data: " <> line <> "\n" | line <- BSC.split '\n' bs ]

-- | Render multiple 'SseEvent' frames to a contiguous wire byte stream.
--
-- @since 0.1.0.0
renderSseStream :: [SseEvent] -> ByteString
renderSseStream events = BS.concat (map renderSseEvent events)
EOF

# 4. Update Sarutahiko.JsonRpc.Types
cat <<'EOF' > packages/sarutahiko/sarutahiko-jsonrpc/src/Sarutahiko/JsonRpc/Types.hs
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
EOF

# 5. Update Sarutahiko.JsonRpc.Dispatch
cat <<'EOF' > packages/sarutahiko/sarutahiko-jsonrpc/src/Sarutahiko/JsonRpc/Dispatch.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Sarutahiko.JsonRpc.Dispatch
-- Description : JSON-RPC 2.0 framing, dispatching, and notification silence
--
-- Implements Invariant 1 (Standard Error Bounds) and Invariant 2
-- (Notification Silence): spec-conformant framing, batching, error dispatch,
-- and row-typed method registration using 'kogaki-wire'.
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'.
module Sarutahiko.JsonRpc.Dispatch
  ( -- * Dispatcher Types
    Dispatcher (..)
  , MethodHandler
  , emptyDispatcher

    -- * Method Registration
  , registerMethod
  , registerRawMethod

    -- * Dispatch Execution
  , dispatchPayload
  , dispatchBatch
  , dispatchTypedBatch
  , dispatchSingleRequest
  , parseRawRequests
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.NonNull (NonNull, fromNullable, toNullable)
import qualified Data.NonNull as NN
import Data.Record.Anon (AllFields, KnownFields)
import Data.Record.Anon.Advanced (Record)
import Data.Text (Text)
import qualified Data.Text as T

import Kogaki.Wire.Json.Decode
  ( FromJsonField
  , ToJsonField
  , decodeJsonRow
  , encodeJsonRow
  , extractObjectFields
  , renderTokens
  , splitValueTokens
  )
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.JsonRpc.Error
  ( errInvalidParams
  , errInvalidRequest
  , errMethodNotFound
  , errParseError
  )
import Sarutahiko.JsonRpc.Types
  ( JsonRpcError (..)
  , JsonRpcId (..)
  , JsonRpcRequest (..)
  , RawJsonRpcRequest (..)
  , encodeJsonRpcError
  , encodeJsonRpcId
  , parseJsonRpcId
  )

-- | Handler mapping an optional raw JSON params slice to either an error or an
-- encoded result byte slice in monad 'm'.
type MethodHandler m = Maybe ByteString -> m (Either JsonRpcError ByteString)

-- | Dispatcher holding registered method handlers.
--
-- @since 0.1.0.0
newtype Dispatcher m = Dispatcher
  { dispatchMethods :: Map (NonNull Text) (MethodHandler m)
  }

-- | Empty dispatcher with zero registered methods.
--
-- @since 0.1.0.0
emptyDispatcher :: Dispatcher m
emptyDispatcher = Dispatcher Map.empty

-- | Register a strongly typed method handler operating on extensible row records.
-- Automatically deserializes arguments via 'decodeJsonRow' and canonicalizes
-- output via 'encodeJsonRow'.
--
-- @since 0.1.0.0
registerMethod
  :: forall inRow outRow m. (Monad m, KnownFields inRow, AllFields inRow FromJsonField, KnownFields outRow, AllFields outRow ToJsonField)
  => NonNull Text
  -> (Record Identity inRow -> m (Record Identity outRow))
  -> Dispatcher m
  -> Dispatcher m
registerMethod method handler (Dispatcher methods) =
  let wrappedHandler mParams =
        let paramBytes = case mParams of
              Nothing -> "{}"
              Just bs | BS.null bs -> "{}"
                      | otherwise  -> bs
        in case decodeJsonRow @inRow paramBytes of
             Nothing -> pure (Left (errInvalidParams ("Failed to decode parameters for: " <> toNullable method)))
             Just inRec -> do
               outRec <- handler inRec
               pure (Right (encodeJsonRow outRec))
  in Dispatcher (Map.insert method wrappedHandler methods)

-- | Register an untyped raw method handler.
--
-- @since 0.1.0.0
registerRawMethod
  :: NonNull Text
  -> MethodHandler m
  -> Dispatcher m
  -> Dispatcher m
registerRawMethod method handler (Dispatcher methods) =
  Dispatcher (Map.insert method handler methods)

-- | Dispatch an incoming JSON-RPC payload (either a single request or a batch array).
--
-- Satisfies Invariant 2 (Notification Silence):
-- If the payload consists solely of notifications, returns 'Nothing'.
--
-- @since 0.1.0.0
dispatchPayload
  :: (Monad m)
  => Dispatcher m
  -> ByteString
  -> m (Maybe ByteString)
dispatchPayload dispatcher input = do
  case parseRawRequests input of
    Left parseErr ->
      -- Parse error on the whole payload produces a failure response with null id
      pure (Just (renderFailure Nothing parseErr))

    Right (isBatch, rawRequests) ->
      case fromNullable rawRequests of
        Nothing ->
          -- Empty batch [] is an invalid request per JSON-RPC 2.0 spec §6
          if isBatch
            then pure (Just (renderFailure Nothing (errInvalidRequest "Empty batch array")))
            else pure Nothing
        Just validBatch ->
          if isBatch
            then dispatchBatch dispatcher validBatch
            else dispatchSingleRequest dispatcher (NN.head validBatch)

-- | Dispatch a validated non-empty batch of requests.
--
-- @since 0.1.0.0
dispatchBatch
  :: (Monad m)
  => Dispatcher m
  -> NonNull [Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest]
  -> m (Maybe ByteString)
dispatchBatch dispatcher requests = do
  responses <- mapM (dispatchSingleRequest dispatcher) (toNullable requests)
  case fromNullable (catMaybes responses) of
    Nothing -> pure Nothing -- All were notifications: Notification Silence (Invariant 2)
    Just activeResponses ->
      pure (Just ("[" <> BS.intercalate "," (toNullable activeResponses) <> "]"))

-- | Dispatch a strongly typed non-empty batch of requests.
--
-- @since 0.1.0.0
dispatchTypedBatch
  :: forall r m. (Monad m, KnownFields r, AllFields r ToJsonField)
  => Dispatcher m
  -> NonNull [JsonRpcRequest r]
  -> m (Maybe ByteString)
dispatchTypedBatch dispatcher requests = do
  let rawRequests = map toRaw (toNullable requests)
  case fromNullable (map Right rawRequests) of
    Nothing -> pure Nothing
    Just nnEither -> dispatchBatch dispatcher nnEither
  where
    toRaw req = RawJsonRpcRequest (reqId req) (reqMethod req) (Just (encodeJsonRow (reqParams req)))

-- | Dispatch a single parsed raw request.
--
-- Returns 'Nothing' if the request is a notification (reqId = Nothing).
--
-- @since 0.1.0.0
dispatchSingleRequest
  :: (Monad m)
  => Dispatcher m
  -> Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest
  -> m (Maybe ByteString)
dispatchSingleRequest _ (Left (mId, err)) =
  -- Structural validation failure on an individual request
  pure (Just (renderFailure mId err))

dispatchSingleRequest (Dispatcher methods) (Right (RawJsonRpcRequest mId method mParams)) =
  case Map.lookup method methods of
    Nothing ->
      case mId of
        Nothing -> pure Nothing -- Notification silence
        Just reqIdent ->
          pure (Just (renderFailure (Just reqIdent) (errMethodNotFound (toNullable method))))

    Just handler -> do
      result <- handler mParams
      case mId of
        Nothing -> pure Nothing -- Notification silence (Invariant 2)
        Just reqIdent ->
          case result of
            Left err -> pure (Just (renderFailure (Just reqIdent) err))
            Right resBytes ->
              pure (Just (renderSuccess reqIdent resBytes))

-- | Render a JSON-RPC 2.0 success frame.
renderSuccess :: JsonRpcId -> ByteString -> ByteString
renderSuccess ident resultBytes =
  "{\"id\":" <> encodeJsonRpcId ident <> ",\"jsonrpc\":\"2.0\",\"result\":" <> resultBytes <> "}"

-- | Render a JSON-RPC 2.0 error frame.
renderFailure :: Maybe JsonRpcId -> JsonRpcError -> ByteString
renderFailure mIdent err =
  let idPart = maybe "null" encodeJsonRpcId mIdent
  in "{\"error\":" <> encodeJsonRpcError err <> ",\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\"}"

-- | Parse raw input into either a top-level error or a list of parsed request descriptors.
-- Returns '(isBatch, [parsedRequests])'.
parseRawRequests
  :: ByteString
  -> Either JsonRpcError (Bool, [Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest])
parseRawRequests bs =
  case lexJsonEither bs of
    Left err -> Left (errParseError err)
    Right [] -> Left (errParseError "Empty input")
    Right (TkArrayOpen : rest) -> do
      reqTokenBatches <- splitArrayBatches rest
      let parsed = map parseSingleRawObject reqTokenBatches
      Right (True, parsed)
    Right tokens@(TkObjectOpen : _) -> do
      let parsed = parseSingleRawObject tokens
      Right (False, [parsed])
    Right (tok : _) ->
      Left (errInvalidRequest ("Top-level JSON-RPC must be object or array, got: " <> T.pack (show tok)))

-- | Parse a single JSON object token slice into a 'RawJsonRpcRequest' or error.
parseSingleRawObject
  :: [JsonToken]
  -> Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest
parseSingleRawObject tokens =
  case extractObjectFields tokens of
    Left err -> Left (Nothing, errInvalidRequest err)
    Right fieldMap ->
      let mId = case Map.lookup "id" fieldMap of
            Nothing    -> Nothing
            Just idTks -> parseJsonRpcId idTks

          -- Check "jsonrpc" == "2.0"
          isJsonRpc2 = case Map.lookup "jsonrpc" fieldMap of
            Just [TkString "2.0"] -> True
            _                     -> False

          -- Check "method" non-emptiness
          mMethod = case Map.lookup "method" fieldMap of
            Just [TkString m] -> fromNullable m
            _                 -> Nothing

          -- Extract "params" slice
          mParams = case Map.lookup "params" fieldMap of
            Nothing       -> Nothing
            Just paramTks -> Just (renderTokens paramTks)

      in if not isJsonRpc2
           then Left (mId, errInvalidRequest "Missing or invalid 'jsonrpc' version; must be '2.0'")
           else case mMethod of
             Nothing -> Left (mId, errInvalidRequest "Missing or invalid 'method' (must be non-empty string)")
             Just method ->
               Right (RawJsonRpcRequest mId method mParams)

-- | Split array items into discrete token sequences.
splitArrayBatches :: [JsonToken] -> Either JsonRpcError [[JsonToken]]
splitArrayBatches [] = Left (errParseError "Unclosed array")
splitArrayBatches (TkArrayClose : _) = Right []
splitArrayBatches tokens = do
  case splitValueTokens tokens of
    Left err -> Left (errParseError err)
    Right (itemTokens, remainder) -> do
      case remainder of
        (TkArrayClose : _) -> Right [itemTokens]
        _                  -> (itemTokens :) <$> splitArrayBatches remainder
EOF

# 6. Update Sarutahiko.MCP.Server
cat <<'EOF' > packages/sarutahiko/sarutahiko-mcp/src/Sarutahiko/MCP/Server.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.MCP.Server
-- Description : MCP 2025-03-26 server engine enforcing the StateGuard invariant
--
-- Implements Task Packet TP-1.5: stdio and memory-backed MCP protocol server hosting
-- agent tools, handling handshakes, and enforcing the StateGuard rejection invariant
-- (-32600 ServerNotInitialized on any request received prior to notifications/initialized).
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'.
module Sarutahiko.MCP.Server
  ( -- * Server Instance
    McpServer
  , newMcpServer
  , getServerState
  , registerTool

    -- * Protocol Handling
  , handleMcpPayload
  , handleMcpRequest

    -- * StateGuard Invariant
  , checkStateGuard

    -- * Wire Response Formatters
  , formatSuccessResponse
  , formatErrorResponse
  ) where

import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.NonNull (fromNullable, toNullable)
import qualified Data.NonNull as NN
import Data.Text (Text)

import Sarutahiko.JsonRpc.Dispatch (parseRawRequests)
import Sarutahiko.JsonRpc.Error
  ( errInvalidParams
  , errInvalidRequest
  , errMethodNotFound
  , errServerNotInitialized
  )
import Sarutahiko.JsonRpc.Types
  ( JsonRpcError (..)
  , JsonRpcId (..)
  , RawJsonRpcRequest (..)
  , encodeJsonRpcError
  , encodeJsonRpcId
  )
import Sarutahiko.MCP.Types
  ( CallToolParams (..)
  , Implementation (..)
  , InitializeParams (..)
  , InitializeResult (..)
  , ListToolsResult (..)
  , McpServerState (..)
  , ToolDef (..)
  , ToolHandler
  , decodeCallToolParams
  , decodeInitializeParams
  , encodeCallToolResult
  , encodeInitializeResult
  , encodeListToolsResult
  , initialServerState
  , mcpVersion2025_03_26
  )

-- | Server state handle backed by a thread-safe 'MVar'.
data McpServer = McpServer
  { msServerInfo :: !Implementation
  , msStateVar   :: !(MVar McpServerState)
  }

-- | Create a new uninitialized MCP server with the given server information.
newMcpServer :: Implementation -> IO McpServer
newMcpServer info = do
  var <- newMVar initialServerState
  pure (McpServer info var)

-- | Read current server state snapshot.
getServerState :: McpServer -> IO McpServerState
getServerState = readMVar . msStateVar

-- | Register a tool definition and its execution handler.
registerTool :: McpServer -> ToolDef -> ToolHandler -> IO ()
registerTool server def handler =
  modifyMVar (msStateVar server) $ \st -> do
    let updatedTools = Map.insert (toolName def) (def, handler) (registeredTools st)
    pure (st { registeredTools = updatedTools }, ())

-- | StateGuard invariant checker:
-- Returns 'Nothing' if the request is permitted, or 'Just JsonRpcError' if rejected.
-- Invariant: Any request other than "initialize" or "ping" received prior to
-- "notifications/initialized" MUST be rejected with error code -32600.
checkStateGuard :: Bool -> Text -> Maybe JsonRpcError
checkStateGuard initialized method
  | initialized = Nothing
  | method == "initialize" = Nothing
  | method == "ping" = Nothing
  | method == "notifications/initialized" = Nothing
  | otherwise = Just (errServerNotInitialized "Server not initialized: request received before notifications/initialized")

-- | Handle an incoming raw JSON-RPC payload string, returning an optional serialized response.
handleMcpPayload :: McpServer -> ByteString -> IO (Maybe ByteString)
handleMcpPayload server payload = do
  case parseRawRequests payload of
    Left parseErr ->
      pure (Just (formatErrorResponse Nothing parseErr))
    Right (isBatch, rawRequests) ->
      case fromNullable rawRequests of
        Nothing ->
          if isBatch
            then pure (Just (formatErrorResponse Nothing (errInvalidRequest "Empty batch array")))
            else pure Nothing
        Just validBatch ->
          if isBatch
            then do
              responses <- mapM (handleMcpRequest server) (toNullable validBatch)
              case fromNullable (catMaybes responses) of
                Nothing -> pure Nothing
                Just activeResponses ->
                  pure (Just ("[" <> BS.intercalate "," (toNullable activeResponses) <> "]"))
            else handleMcpRequest server (NN.head validBatch)

-- | Handle a single raw JSON-RPC request.
handleMcpRequest
  :: McpServer
  -> Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest
  -> IO (Maybe ByteString)
handleMcpRequest _ (Left (mId, err)) =
  pure (Just (formatErrorResponse mId err))

handleMcpRequest server (Right (RawJsonRpcRequest mId method mParams)) = do
  st <- readMVar (msStateVar server)
  case checkStateGuard (isInitialized st) (toNullable method) of
    Just err ->
      case mId of
        Nothing -> pure Nothing
        Just reqIdent -> pure (Just (formatErrorResponse (Just reqIdent) err))
    Nothing -> do
      case toNullable method of
        "initialize" -> do
          case mParams of
            Nothing ->
              pure (Just (formatErrorResponse mId (errInvalidParams "Missing initialize parameters")))
            Just pBytes ->
              case decodeInitializeParams pBytes of
                Nothing ->
                  pure (Just (formatErrorResponse mId (errInvalidParams "Malformed initialize parameters")))
                Just _initParams -> do
                  let res = InitializeResult
                        { irProtocolVersion = mcpVersion2025_03_26
                        , irCapabilities     = defaultServerCapabilities
                        , irServerInfo       = msServerInfo server
                        }
                  pure (Just (formatSuccessResponse mId (encodeInitializeResult res)))

        "notifications/initialized" -> do
          modifyMVar (msStateVar server) $ \s ->
            pure (s { isInitialized = True }, ())
          pure Nothing

        "ping" ->
          pure (Just (formatSuccessResponse mId "{}"))

        "tools/list" -> do
          let toolDefs = map fst (Map.elems (registeredTools st))
              res = ListToolsResult toolDefs Nothing
          pure (Just (formatSuccessResponse mId (encodeListToolsResult res)))

        "tools/call" -> do
          case mParams of
            Nothing ->
              pure (Just (formatErrorResponse mId (errInvalidParams "Missing tools/call parameters")))
            Just pBytes ->
              case decodeCallToolParams pBytes of
                Nothing ->
                  pure (Just (formatErrorResponse mId (errInvalidParams "Malformed tools/call parameters")))
                Just callParams -> do
                  case Map.lookup (cpName callParams) (registeredTools st) of
                    Nothing ->
                      pure (Just (formatErrorResponse mId (errMethodNotFound ("Tool not found: " <> cpName callParams))))
                    Just (_, handler) -> do
                      toolRes <- handler (cpArguments callParams)
                      pure (Just (formatSuccessResponse mId (encodeCallToolResult toolRes)))

        _ ->
          case mId of
            Nothing -> pure Nothing
            Just reqIdent ->
              pure (Just (formatErrorResponse (Just reqIdent) (errMethodNotFound (toNullable method))))

-- | Format a success response with the given result payload bytes.
formatSuccessResponse :: Maybe JsonRpcId -> ByteString -> ByteString
formatSuccessResponse mIdent resultBytes =
  let idPart = maybe "null" encodeJsonRpcId mIdent
  in "{\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\",\"result\":" <> resultBytes <> "}"

-- | Format an error response for the given JSON-RPC error.
formatErrorResponse :: Maybe JsonRpcId -> JsonRpcError -> ByteString
formatErrorResponse mIdent err =
  let idPart = maybe "null" encodeJsonRpcId mIdent
  in "{\"error\":" <> encodeJsonRpcError err <> ",\"id\":" <> idPart <> ",\"jsonrpc\":\"2.0\"}"
EOF

echo "=== [sweep-02] Transformation script complete ==="

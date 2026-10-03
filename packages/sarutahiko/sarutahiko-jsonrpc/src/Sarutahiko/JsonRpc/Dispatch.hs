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

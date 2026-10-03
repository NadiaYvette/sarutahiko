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

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
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
  , defaultServerCapabilities
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
              responses <- mapM (dispatchParsedRequest server) (toNullable validBatch)
              case fromNullable (catMaybes responses) of
                Nothing -> pure Nothing
                Just activeResponses ->
                  pure (Just ("[" <> BS.intercalate "," (toNullable activeResponses) <> "]"))
            else dispatchParsedRequest server (NN.head validBatch)

-- | Dispatch an item parsed by 'parseRawRequests'.
dispatchParsedRequest
  :: McpServer
  -> Either (Maybe JsonRpcId, JsonRpcError) RawJsonRpcRequest
  -> IO (Maybe ByteString)
dispatchParsedRequest _ (Left (mId, err)) =
  pure (Just (formatErrorResponse mId err))
dispatchParsedRequest server (Right rawReq) =
  handleMcpRequest server rawReq

-- | Handle a single raw JSON-RPC request frame.
handleMcpRequest :: McpServer -> RawJsonRpcRequest -> IO (Maybe ByteString)
handleMcpRequest server req = do
  st <- readMVar (msStateVar server)
  let mId = rawReqId req
      method = toNullable (rawReqMethod req)
      mParams = rawReqParams req

  -- Check StateGuard invariant
  case checkStateGuard (serverInitialized st) method of
    Just err ->
      pure (Just (formatErrorResponse mId err))
    Nothing ->
      dispatchMethod server st mId method mParams

-- | Internal method dispatch for permitted methods.
dispatchMethod
  :: McpServer
  -> McpServerState
  -> Maybe JsonRpcId
  -> Text
  -> Maybe ByteString
  -> IO (Maybe ByteString)
dispatchMethod server st mId method mParams = case method of
  "initialize" -> do
    case mParams of
      Nothing ->
        pure (Just (formatErrorResponse mId (errInvalidParams "Missing initialize params")))
      Just paramsBytes ->
        case decodeInitializeParams paramsBytes of
          Left decodeErr ->
            pure (Just (formatErrorResponse mId (errInvalidParams decodeErr)))
          Right ip -> do
            -- Record client capabilities in state
            modifyMVar (msStateVar server) $ \s ->
              pure (s { clientCapabilities = Just (ipCapabilities ip) }, ())
            let result = InitializeResult
                  { irProtocolVersion = mcpVersion2025_03_26
                  , irCapabilities     = defaultServerCapabilities
                  , irServerInfo       = msServerInfo server
                  , irInstructions     = Just "Sarutahiko MCP Server ready."
                  }
                resBytes = encodeInitializeResult result
            case mId of
              Nothing  -> pure Nothing
              Just reqId -> pure (Just (formatSuccessResponse reqId resBytes))

  "notifications/initialized" -> do
    -- Transition server state to initialized = True
    modifyMVar (msStateVar server) $ \s ->
      pure (s { serverInitialized = True }, ())
    -- Notifications MUST NOT produce a wire response
    pure Nothing

  "ping" ->
    case mId of
      Nothing  -> pure Nothing
      Just reqId -> pure (Just (formatSuccessResponse reqId "{}"))

  "tools/list" -> do
    let tools = [def | (def, _) <- Map.elems (registeredTools st)]
        result = ListToolsResult
          { ltrTools      = tools
          , ltrNextCursor = Nothing
          }
        resBytes = encodeListToolsResult result
    case mId of
      Nothing  -> pure Nothing
      Just reqId -> pure (Just (formatSuccessResponse reqId resBytes))

  "tools/call" -> do
    case mParams of
      Nothing ->
        pure (Just (formatErrorResponse mId (errInvalidParams "Missing tools/call params")))
      Just paramsBytes ->
        case decodeCallToolParams paramsBytes of
          Left decodeErr ->
            pure (Just (formatErrorResponse mId (errInvalidParams decodeErr)))
          Right ctp -> do
            let tName = ctpName ctp
            case Map.lookup tName (registeredTools st) of
              Nothing ->
                pure (Just (formatErrorResponse mId (errMethodNotFound ("Unknown tool: " <> tName))))
              Just (_, handler) -> do
                callRes <- handler (ctpArguments ctp)
                let resBytes = encodeCallToolResult callRes
                case mId of
                  Nothing  -> pure Nothing
                  Just reqId -> pure (Just (formatSuccessResponse reqId resBytes))

  otherMethod ->
    case mId of
      Nothing  -> pure Nothing
      Just reqId -> pure (Just (formatErrorResponse (Just reqId) (errMethodNotFound otherMethod)))

-- | Helper to format a JSON-RPC 2.0 success response.
formatSuccessResponse :: JsonRpcId -> ByteString -> ByteString
formatSuccessResponse reqId resultBytes =
  "{\"id\":" <> encodeJsonRpcId reqId <> ",\"jsonrpc\":\"2.0\",\"result\":" <> resultBytes <> "}"

-- | Helper to format a JSON-RPC 2.0 error response.
formatErrorResponse :: Maybe JsonRpcId -> JsonRpcError -> ByteString
formatErrorResponse mId err =
  "{\"error\":" <> encodeJsonRpcError err <> ",\"id\":" <> maybe "null" encodeJsonRpcId mId <> ",\"jsonrpc\":\"2.0\"}"

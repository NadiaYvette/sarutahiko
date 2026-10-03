{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

-- |
-- Module      : Sarutahiko.MCP.Types
-- Description : Core Model Context Protocol (MCP 2025-03-26) wire types and codecs
--
-- Implements Task Packet TP-1.5: spec-conformant MCP protocol data types,
-- capability negotiation structures, tool schemas, and zero-aeson row codecs.
module Sarutahiko.MCP.Types
  ( -- * Protocol Version
    mcpVersion2025_03_26
  , ProtocolVersion (..)

    -- * Implementation Info
  , Implementation (..)
  , encodeImplementation
  , decodeImplementation

    -- * Capabilities
  , ClientCapabilities (..)
  , ServerCapabilities (..)
  , defaultClientCapabilities
  , defaultServerCapabilities
  , encodeClientCapabilities
  , decodeClientCapabilities
  , encodeServerCapabilities
  , decodeServerCapabilities

    -- * Handshake (initialize)
  , InitializeParams (..)
  , InitializeResult (..)
  , encodeInitializeParams
  , decodeInitializeParams
  , encodeInitializeResult
  , decodeInitializeResult

    -- * Tool Definitions & Listing
  , ToolDef (..)
  , ListToolsResult (..)
  , encodeToolDef
  , decodeToolDef
  , encodeListToolsResult
  , decodeListToolsResult

    -- * Tool Invocations (tools/call)
  , CallToolParams (..)
  , ToolContent (..)
  , CallToolResult (..)
  , encodeCallToolParams
  , decodeCallToolParams
  , encodeCallToolResult
  , decodeCallToolResult

    -- * Server State & Handler Types
  , ToolHandler
  , McpServerState (..)
  , initialServerState
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Kogaki.Wire.Json.Decode
  ( FromJsonField (..)
  , ToJsonField (..)
  , extractObjectFields
  , renderTokens
  , splitValueTokens
  )
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.Schema.Types (SchemaNode (..), schemaNodeToJson)

-- ----------------------------------------------------------------------------
-- Protocol Version
-- ----------------------------------------------------------------------------

-- | The canonical MCP specification version implemented by this package.
mcpVersion2025_03_26 :: Text
mcpVersion2025_03_26 = "2025-03-26"

-- | Protocol version wrapper.
newtype ProtocolVersion = ProtocolVersion { unProtocolVersion :: Text }
  deriving stock (Eq, Ord, Show, Generic)

instance FromJsonField ProtocolVersion where
  decodeField mToks = ProtocolVersion <$> decodeField mToks

instance ToJsonField ProtocolVersion where
  encodeField (ProtocolVersion v) = encodeField v

-- ----------------------------------------------------------------------------
-- Implementation Info
-- ----------------------------------------------------------------------------

-- | Information about the client or server implementation.
data Implementation = Implementation
  { implName    :: !Text
  , implVersion :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Encode 'Implementation' to JSON bytes.
encodeImplementation :: Implementation -> ByteString
encodeImplementation (Implementation name ver) =
  "{\"name\":\"" <> escapeJson (TE.encodeUtf8 name) <>
  "\",\"version\":\"" <> escapeJson (TE.encodeUtf8 ver) <> "\"}"

-- | Decode 'Implementation' from token stream.
decodeImplementation :: [JsonToken] -> Either Text Implementation
decodeImplementation toks = do
  fields <- extractObjectFields toks
  nameToks <- maybe (Left "Missing 'name' in implementation info") Right (Map.lookup "name" fields)
  verToks  <- maybe (Left "Missing 'version' in implementation info") Right (Map.lookup "version" fields)
  name <- decodeField (Just nameToks)
  ver  <- decodeField (Just verToks)
  Right (Implementation name ver)

-- ----------------------------------------------------------------------------
-- Capabilities
-- ----------------------------------------------------------------------------

-- | Capabilities supported by an MCP client.
data ClientCapabilities = ClientCapabilities
  { ccRoots       :: !(Maybe Bool)
  , ccSampling    :: !(Maybe Bool)
  , ccExperimental :: !(Maybe (Map Text Text))
  } deriving stock (Eq, Show, Generic)

-- | Default minimal client capabilities.
defaultClientCapabilities :: ClientCapabilities
defaultClientCapabilities = ClientCapabilities Nothing Nothing Nothing

-- | Encode 'ClientCapabilities' to JSON bytes.
encodeClientCapabilities :: ClientCapabilities -> ByteString
encodeClientCapabilities cc =
  let pairs = catMaybes
        [ (\r -> "\"roots\":{\"listChanged\":" <> if r then "true}" else "false}") <$> ccRoots cc
        , (\s -> "\"sampling\":" <> if s then "{}" else "null") <$> ccSampling cc
        ]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode 'ClientCapabilities' from token stream.
decodeClientCapabilities :: [JsonToken] -> Either Text ClientCapabilities
decodeClientCapabilities toks = do
  fields <- extractObjectFields toks
  let mRootsToks = Map.lookup "roots" fields
      mSamplingToks = Map.lookup "sampling" fields
  roots <- case mRootsToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  sampling <- case mSamplingToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  Right (ClientCapabilities roots sampling Nothing)

-- | Capabilities supported by an MCP server.
data ServerCapabilities = ServerCapabilities
  { scLogging      :: !(Maybe Bool)
  , scPrompts      :: !(Maybe Bool)
  , scResources    :: !(Maybe Bool)
  , scTools        :: !(Maybe Bool)
  , scExperimental :: !(Maybe (Map Text Text))
  } deriving stock (Eq, Show, Generic)

-- | Default minimal server capabilities (tools advertised as supported).
defaultServerCapabilities :: ServerCapabilities
defaultServerCapabilities = ServerCapabilities
  { scLogging      = Just False
  , scPrompts      = Just False
  , scResources    = Just False
  , scTools        = Just True
  , scExperimental = Nothing
  }

-- | Encode 'ServerCapabilities' to JSON bytes.
encodeServerCapabilities :: ServerCapabilities -> ByteString
encodeServerCapabilities sc =
  let pairs = catMaybes
        [ (\l -> "\"logging\":" <> if l then "{}" else "null") <$> scLogging sc
        , (\p -> "\"prompts\":{\"listChanged\":" <> if p then "true}" else "false}") <$> scPrompts sc
        , (\r -> "\"resources\":{\"listChanged\":" <> if r then "true}" else "false}") <$> scResources sc
        , (\t -> "\"tools\":{\"listChanged\":" <> if t then "true}" else "false}") <$> scTools sc
        ]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode 'ServerCapabilities' from token stream.
decodeServerCapabilities :: [JsonToken] -> Either Text ServerCapabilities
decodeServerCapabilities toks = do
  fields <- extractObjectFields toks
  let mToolsToks = Map.lookup "tools" fields
      mLoggingToks = Map.lookup "logging" fields
      mPromptsToks = Map.lookup "prompts" fields
      mResourcesToks = Map.lookup "resources" fields
  tools <- case mToolsToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  logging <- case mLoggingToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  prompts <- case mPromptsToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  resources <- case mResourcesToks of
    Nothing -> Right Nothing
    Just _  -> Right (Just True)
  Right (ServerCapabilities logging prompts resources tools Nothing)

-- ----------------------------------------------------------------------------
-- Handshake (initialize)
-- ----------------------------------------------------------------------------

-- | Incoming parameters for @initialize@ request.
data InitializeParams = InitializeParams
  { ipProtocolVersion :: !Text
  , ipCapabilities     :: !ClientCapabilities
  , ipClientInfo       :: !Implementation
  } deriving stock (Eq, Show, Generic)

-- | Encode 'InitializeParams' to JSON bytes.
encodeInitializeParams :: InitializeParams -> ByteString
encodeInitializeParams (InitializeParams ver caps client) =
  "{\"protocolVersion\":\"" <> escapeJson (TE.encodeUtf8 ver) <>
  "\",\"capabilities\":" <> encodeClientCapabilities caps <>
  ",\"clientInfo\":" <> encodeImplementation client <> "}"

-- | Decode 'InitializeParams' from JSON bytes.
decodeInitializeParams :: ByteString -> Either Text InitializeParams
decodeInitializeParams bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  pvToks <- maybe (Left "Missing 'protocolVersion'") Right (Map.lookup "protocolVersion" fields)
  capToks <- maybe (Left "Missing 'capabilities'") Right (Map.lookup "capabilities" fields)
  ciToks <- maybe (Left "Missing 'clientInfo'") Right (Map.lookup "clientInfo" fields)
  pv <- decodeField (Just pvToks)
  caps <- decodeClientCapabilities capToks
  ci <- decodeImplementation ciToks
  Right (InitializeParams pv caps ci)

-- | Outgoing result for @initialize@ request.
data InitializeResult = InitializeResult
  { irProtocolVersion :: !Text
  , irCapabilities     :: !ServerCapabilities
  , irServerInfo       :: !Implementation
  , irInstructions     :: !(Maybe Text)
  } deriving stock (Eq, Show, Generic)

-- | Encode 'InitializeResult' to JSON bytes.
encodeInitializeResult :: InitializeResult -> ByteString
encodeInitializeResult (InitializeResult ver caps server mInstr) =
  let pairs =
        [ "\"protocolVersion\":\"" <> escapeJson (TE.encodeUtf8 ver) <> "\""
        , "\"capabilities\":" <> encodeServerCapabilities caps
        , "\"serverInfo\":" <> encodeImplementation server
        ] ++ catMaybes [(\i -> "\"instructions\":\"" <> escapeJson (TE.encodeUtf8 i) <> "\"") <$> mInstr]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode 'InitializeResult' from JSON bytes.
decodeInitializeResult :: ByteString -> Either Text InitializeResult
decodeInitializeResult bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  pvToks <- maybe (Left "Missing 'protocolVersion'") Right (Map.lookup "protocolVersion" fields)
  capToks <- maybe (Left "Missing 'capabilities'") Right (Map.lookup "capabilities" fields)
  siToks <- maybe (Left "Missing 'serverInfo'") Right (Map.lookup "serverInfo" fields)
  pv <- decodeField (Just pvToks)
  caps <- decodeServerCapabilities capToks
  si <- decodeImplementation siToks
  let mInstrToks = Map.lookup "instructions" fields
  mInstr <- case mInstrToks of
    Nothing -> Right Nothing
    Just it -> Just <$> decodeField (Just it)
  Right (InitializeResult pv caps si mInstr)

-- ----------------------------------------------------------------------------
-- Tool Definitions & Listing
-- ----------------------------------------------------------------------------

-- | Definition of an exposed tool advertised in @tools/list@.
data ToolDef = ToolDef
  { toolName        :: !Text
  , toolDescription :: !(Maybe Text)
  , toolInputSchema :: !SchemaNode
  } deriving stock (Eq, Show, Generic)

-- | Encode a 'ToolDef' to JSON bytes.
encodeToolDef :: ToolDef -> ByteString
encodeToolDef (ToolDef name mDesc schema) =
  let pairs =
        [ "\"name\":\"" <> escapeJson (TE.encodeUtf8 name) <> "\""
        , "\"inputSchema\":" <> schemaNodeToJson schema
        ] ++ catMaybes [(\d -> "\"description\":\"" <> escapeJson (TE.encodeUtf8 d) <> "\"") <$> mDesc]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode a 'ToolDef' from token stream.
decodeToolDef :: [JsonToken] -> Either Text ToolDef
decodeToolDef toks = do
  fields <- extractObjectFields toks
  nameToks <- maybe (Left "Missing 'name' in tool definition") Right (Map.lookup "name" fields)
  name <- decodeField (Just nameToks)
  let mDescToks = Map.lookup "description" fields
  mDesc <- case mDescToks of
    Nothing -> Right Nothing
    Just dt -> Just <$> decodeField (Just dt)
  -- For inputSchema, default to empty object schema if absent/opaque
  let schema = SchemaObject Map.empty []
  Right (ToolDef name mDesc schema)

-- | Result of a @tools/list@ request.
data ListToolsResult = ListToolsResult
  { ltrTools      :: ![ToolDef]
  , ltrNextCursor :: !(Maybe Text)
  } deriving stock (Eq, Show, Generic)

-- | Encode 'ListToolsResult' to JSON bytes.
encodeListToolsResult :: ListToolsResult -> ByteString
encodeListToolsResult (ListToolsResult tools mCursor) =
  let toolsArr = "[" <> BS.intercalate "," (map encodeToolDef tools) <> "]"
      pairs =
        [ "\"tools\":" <> toolsArr ]
        ++ catMaybes [(\c -> "\"nextCursor\":\"" <> escapeJson (TE.encodeUtf8 c) <> "\"") <$> mCursor]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode 'ListToolsResult' from JSON bytes.
decodeListToolsResult :: ByteString -> Either Text ListToolsResult
decodeListToolsResult bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  toolsToks <- maybe (Left "Missing 'tools' array") Right (Map.lookup "tools" fields)
  toolElems <- parseArrayElements toolsToks
  tools <- mapM decodeToolDef toolElems
  let mCursorToks = Map.lookup "nextCursor" fields
  mCursor <- case mCursorToks of
    Nothing -> Right Nothing
    Just ct -> Just <$> decodeField (Just ct)
  Right (ListToolsResult tools mCursor)

-- ----------------------------------------------------------------------------
-- Tool Invocations (tools/call)
-- ----------------------------------------------------------------------------

-- | Parameters for a @tools/call@ request.
data CallToolParams = CallToolParams
  { ctpName      :: !Text
  , ctpArguments :: !(Maybe ByteString)
  } deriving stock (Eq, Show, Generic)

-- | Encode 'CallToolParams' to JSON bytes.
encodeCallToolParams :: CallToolParams -> ByteString
encodeCallToolParams (CallToolParams name mArgs) =
  let pairs =
        [ "\"name\":\"" <> escapeJson (TE.encodeUtf8 name) <> "\""
        ] ++ catMaybes [(\args -> "\"arguments\":" <> args) <$> mArgs]
  in "{" <> BS.intercalate "," pairs <> "}"

-- | Decode 'CallToolParams' from JSON bytes.
decodeCallToolParams :: ByteString -> Either Text CallToolParams
decodeCallToolParams bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  nameToks <- maybe (Left "Missing 'name' in tools/call params") Right (Map.lookup "name" fields)
  name <- decodeField (Just nameToks)
  let mArgsToks = Map.lookup "arguments" fields
      mArgsBytes = renderTokens <$> mArgsToks
  Right (CallToolParams name mArgsBytes)

-- | Output content from a tool execution.
data ToolContent
  = TextContent !Text
  | ImageContent !Text !Text -- ^ base64 data, mimeType
  deriving stock (Eq, Show, Generic)

-- | Encode a single 'ToolContent' item to JSON bytes.
encodeToolContent :: ToolContent -> ByteString
encodeToolContent (TextContent txt) =
  "{\"type\":\"text\",\"text\":\"" <> escapeJson (TE.encodeUtf8 txt) <> "\"}"
encodeToolContent (ImageContent d mime) =
  "{\"type\":\"image\",\"data\":\"" <> escapeJson (TE.encodeUtf8 d) <>
  "\",\"mimeType\":\"" <> escapeJson (TE.encodeUtf8 mime) <> "\"}"

-- | Decode a 'ToolContent' item from token stream.
decodeToolContent :: [JsonToken] -> Either Text ToolContent
decodeToolContent toks = do
  fields <- extractObjectFields toks
  typeToks <- maybe (Left "Missing 'type' in tool content") Right (Map.lookup "type" fields)
  contentType :: Text <- decodeField (Just typeToks)
  case contentType of
    "text" -> do
      txtToks <- maybe (Left "Missing 'text' in text tool content") Right (Map.lookup "text" fields)
      txt <- decodeField (Just txtToks)
      Right (TextContent txt)
    "image" -> do
      dataToks <- maybe (Left "Missing 'data' in image tool content") Right (Map.lookup "data" fields)
      mimeToks <- maybe (Left "Missing 'mimeType' in image tool content") Right (Map.lookup "mimeType" fields)
      d <- decodeField (Just dataToks)
      mime <- decodeField (Just mimeToks)
      Right (ImageContent d mime)
    other -> Left ("Unsupported tool content type: " <> other)

-- | Result of a @tools/call@ execution.
data CallToolResult = CallToolResult
  { ctrContent :: ![ToolContent]
  , ctrIsError :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | Encode 'CallToolResult' to JSON bytes.
encodeCallToolResult :: CallToolResult -> ByteString
encodeCallToolResult (CallToolResult content isErr) =
  let contentArr = "[" <> BS.intercalate "," (map encodeToolContent content) <> "]"
      errFlag = if isErr then "true" else "false"
  in "{\"content\":" <> contentArr <> ",\"isError\":" <> errFlag <> "}"

-- | Decode 'CallToolResult' from JSON bytes.
decodeCallToolResult :: ByteString -> Either Text CallToolResult
decodeCallToolResult bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  contentToks <- maybe (Left "Missing 'content' array in CallToolResult") Right (Map.lookup "content" fields)
  contentElems <- parseArrayElements contentToks
  contents <- mapM decodeToolContent contentElems
  let mErrToks = Map.lookup "isError" fields
  isErr <- case mErrToks of
    Nothing -> Right False
    Just et -> decodeField (Just et)
  Right (CallToolResult contents isErr)

-- ----------------------------------------------------------------------------
-- Server State & Handler Types
-- ----------------------------------------------------------------------------

-- | Concrete handler for an MCP tool execution.
type ToolHandler = Maybe ByteString -> IO CallToolResult

-- | Internal state of an MCP server session.
data McpServerState = McpServerState
  { serverInitialized  :: !Bool
  , clientCapabilities :: !(Maybe ClientCapabilities)
  , registeredTools    :: !(Map Text (ToolDef, ToolHandler))
  }

-- | Initial uninitialized server state.
initialServerState :: McpServerState
initialServerState = McpServerState
  { serverInitialized  = False
  , clientCapabilities = Nothing
  , registeredTools    = Map.empty
  }

-- ----------------------------------------------------------------------------
-- Token Parsing Helpers
-- ----------------------------------------------------------------------------

-- | Parse token slices of array elements.
parseArrayElements :: [JsonToken] -> Either Text [[JsonToken]]
parseArrayElements [] = Left "Unexpected EOF: expected array"
parseArrayElements (TkArrayOpen : rest) = go rest []
  where
    go [] _ = Left "Unexpected EOF: unclosed array"
    go (TkArrayClose : _) !acc = Right (reverse acc)
    go tks !acc = do
      (elemTokens, remainder) <- splitValueTokens tks
      go remainder (elemTokens : acc)
parseArrayElements (tok : _) = Left ("Expected TkArrayOpen, got: " <> T.pack (show tok))

-- | JSON string byte escaping helper.
escapeJson :: ByteString -> ByteString
escapeJson bs = BSC.concatMap esc bs
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = BSC.singleton c

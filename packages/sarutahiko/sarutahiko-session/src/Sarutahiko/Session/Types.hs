{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Session.Types
-- Description : Core event schemas, session models, and codecs (utaibon / 謡本)
--
-- Implements the exact event rows for the Spine v0.2 protocol per
-- MEMORY_ENGINE_DESIGN.md §3.1 and HOKORA_SPEC.md §5.
module Sarutahiko.Session.Types
  ( -- * Session Event Payloads
    SessionOpenedPayload (..)
  , MessagePayload (..)
  , ToolInvokedPayload (..)
  , ToolObservedPayload (..)
  , SessionClosedPayload (..)

    -- * Encoders & Decoders
  , encodeSessionOpened
  , encodeMessagePayload
  , encodeToolInvoked
  , encodeToolObserved
  , encodeSessionClosed
  , decodeSessionOpened
  , decodeMessagePayload
  , decodeToolInvoked
  , decodeToolObserved
  , decodeSessionClosed

    -- * Session Context & State
  , SessionContext (..)
  , emptySessionContext
  , fnv1a64Hex

    -- * Database Handle
  , SessionHandle (..)
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Database.SQLite3 (Database)
import GHC.Generics (Generic)
import Numeric (showHex)

import Kogaki.Wire.Json.Decode (extractObjectFields, renderTokens)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.Effect.EventStore (SessionId)
import Sarutahiko.Effect.ModelAPI (Message (..), Role (..))

-- | Session opened payload: ("session_opened", 1).
data SessionOpenedPayload = SessionOpenedPayload
  { soModel :: !Text
  , soCwd   :: !FilePath
  } deriving stock (Eq, Show, Generic)

-- | Message payload: ("message", 1).
data MessagePayload = MessagePayload
  { mpRole    :: !Role
  , mpContent :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Tool invoked payload: ("tool_invoked", 1).
data ToolInvokedPayload = ToolInvokedPayload
  { tiName   :: !Text
  , tiCallId :: !Text
  , tiArgs   :: !ByteString
  } deriving stock (Eq, Show, Generic)

-- | Tool observed payload: ("tool_observed", 1).
data ToolObservedPayload = ToolObservedPayload
  { toCallId :: !Text
  , toOutput :: !Text
  , toOk     :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | Session closed payload: ("session_closed", 1).
data SessionClosedPayload = SessionClosedPayload
  { scReason :: !Text
  } deriving stock (Eq, Show, Generic)

-- ----------------------------------------------------------------------------
-- Safe Zero-Aeson Encoders
-- ----------------------------------------------------------------------------

encodeSessionOpened :: Text -> FilePath -> ByteString
encodeSessionOpened model cwd =
  "{\"model\":\"" <> escapeJsonText model <> "\",\"cwd\":\"" <> escapeJsonString cwd <> "\"}"

encodeMessagePayload :: Role -> Text -> ByteString
encodeMessagePayload role content =
  let r = case role of
        RoleSystem    -> "system"
        RoleUser      -> "user"
        RoleAssistant -> "assistant"
        RoleTool      -> "tool"
  in "{\"role\":\"" <> r <> "\",\"content\":\"" <> escapeJsonText content <> "\"}"

encodeToolInvoked :: Text -> Text -> ByteString -> ByteString
encodeToolInvoked name cid args =
  "{\"name\":\"" <> escapeJsonText name
  <> "\",\"callId\":\"" <> escapeJsonText cid
  <> "\",\"args\":\"" <> escapeJsonByteString args <> "\"}"

encodeToolObserved :: Text -> Text -> Bool -> ByteString
encodeToolObserved cid output ok =
  "{\"callId\":\"" <> escapeJsonText cid
  <> "\",\"output\":\"" <> escapeJsonText output
  <> "\",\"ok\":" <> (if ok then "true" else "false") <> "}"

encodeSessionClosed :: Text -> ByteString
encodeSessionClosed reason =
  "{\"reason\":\"" <> escapeJsonText reason <> "\"}"

escapeJsonText :: Text -> ByteString
escapeJsonText = escapeJsonString . T.unpack

escapeJsonByteString :: ByteString -> ByteString
escapeJsonByteString = escapeJsonString . BSC.unpack

escapeJsonString :: String -> ByteString
escapeJsonString str = TE.encodeUtf8 $ T.pack $ concatMap escapeChar str
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = [c]

-- ----------------------------------------------------------------------------
-- Safe Zero-Aeson Decoders
-- ----------------------------------------------------------------------------

decodeSessionOpened :: ByteString -> Either Text SessionOpenedPayload
decodeSessionOpened bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  mToks <- maybe (Left "Missing 'model'") Right (Map.lookup "model" fields)
  cToks <- maybe (Left "Missing 'cwd'") Right (Map.lookup "cwd" fields)
  model <- extractStringValue mToks
  cwd   <- extractStringValue cToks
  Right (SessionOpenedPayload model (T.unpack cwd))

decodeMessagePayload :: ByteString -> Either Text MessagePayload
decodeMessagePayload bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  rToks <- maybe (Left "Missing 'role'") Right (Map.lookup "role" fields)
  cToks <- maybe (Left "Missing 'content'") Right (Map.lookup "content" fields)
  rStr <- extractStringValue rToks
  role <- case rStr of
    "system"    -> Right RoleSystem
    "user"      -> Right RoleUser
    "assistant" -> Right RoleAssistant
    "tool"      -> Right RoleTool
    other       -> Left ("Unknown role: " <> other)
  content <- extractStringValue cToks
  Right (MessagePayload role content)

decodeToolInvoked :: ByteString -> Either Text ToolInvokedPayload
decodeToolInvoked bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  nToks <- maybe (Left "Missing 'name'") Right (Map.lookup "name" fields)
  cToks <- maybe (Left "Missing 'callId'") Right (Map.lookup "callId" fields)
  let aBytes = maybe "{}" renderTokens (Map.lookup "args" fields)
  name <- extractStringValue nToks
  cid  <- extractStringValue cToks
  Right (ToolInvokedPayload name cid aBytes)

decodeToolObserved :: ByteString -> Either Text ToolObservedPayload
decodeToolObserved bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  cToks <- maybe (Left "Missing 'callId'") Right (Map.lookup "callId" fields)
  oToks <- maybe (Left "Missing 'output'") Right (Map.lookup "output" fields)
  let ok = case Map.lookup "ok" fields of
        Just [TkBool b] -> b
        _               -> False
  cid    <- extractStringValue cToks
  output <- extractStringValue oToks
  Right (ToolObservedPayload cid output ok)

decodeSessionClosed :: ByteString -> Either Text SessionClosedPayload
decodeSessionClosed bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  rToks <- maybe (Left "Missing 'reason'") Right (Map.lookup "reason" fields)
  reason <- extractStringValue rToks
  Right (SessionClosedPayload reason)

extractStringValue :: [JsonToken] -> Either Text Text
extractStringValue [TkString s] = Right s
extractStringValue [TkKey k]    = Right (TE.decodeUtf8 k)
extractStringValue _            = Left "Expected JSON string token"

-- ----------------------------------------------------------------------------
-- Deterministic Hash (FNV-1a 64-bit Hex)
-- ----------------------------------------------------------------------------

-- | Compute deterministic 64-bit FNV-1a hash formatted as 16-character hex string.
fnv1a64Hex :: ByteString -> Text
fnv1a64Hex bs =
  let h = BS.foldl' (\acc b -> (acc `xor` fromIntegral b) * 1099511628211) (14695981039346656037 :: Word64) bs
      hexStr = showHex h ""
      padded = replicate (16 - length hexStr) '0' ++ hexStr
  in T.pack padded

-- ----------------------------------------------------------------------------
-- Session Context & Handle
-- ----------------------------------------------------------------------------

-- | Pure session context folded from event stream per MEMORY_ENGINE_DESIGN.md.
data SessionContext = SessionContext
  { scSessionId   :: !SessionId
  , scModel       :: !Text
  , scCwd         :: !FilePath
  , scMessages    :: ![Message]
  , scToolResults :: ![(Text, Text, Bool)] -- ^ (callId, output, ok)
  , scIsClosed    :: !Bool
  , scCloseReason :: !(Maybe Text)
  , scPrefixHash  :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Empty session context.
emptySessionContext :: SessionId -> SessionContext
emptySessionContext sid = SessionContext
  { scSessionId   = sid
  , scModel       = ""
  , scCwd         = ""
  , scMessages    = []
  , scToolResults = []
  , scIsClosed    = False
  , scCloseReason = Nothing
  , scPrefixHash  = ""
  }

-- | Handle to an open session backed by SQLite.
data SessionHandle = SessionHandle
  { shDatabase  :: !Database
  , shSessionId :: !SessionId
  }

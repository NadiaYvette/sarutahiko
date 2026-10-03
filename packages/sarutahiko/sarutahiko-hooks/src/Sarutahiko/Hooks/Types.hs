{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Hooks.Types
-- Description : Data types and wire schemas for shell hooks and consent checking
--
-- Implements hook specs, consent outcomes, and execution contexts per
-- NIH_PLAN.md Tier 2 (sarutahiko-hooks).
module Sarutahiko.Hooks.Types
  ( -- * Hook Classifications
    HookType (..)
  , HookSpec (..)
  , HookConsent (..)
  , HookContext (..)
  , HookResult (..)

    -- * Encoders & Decoders
  , encodeHookContext
  , encodeHookResult
  , decodeHookResult
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Kogaki.Wire.Json.Decode (extractObjectFields)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)

-- | Lifecycle attachment point for a hook.
data HookType
  = PreToolCall
  | PostToolCall
  | PreTurn
  | PostTurn
  deriving stock (Eq, Ord, Show, Generic)

-- | Specification for an executable hook subprocess.
data HookSpec = HookSpec
  { hsType       :: !HookType
  , hsCommand    :: !FilePath
  , hsArgs       :: ![Text]
  , hsTimeoutSec :: !Int
  , hsAllowFail  :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | User/policy consent verdict for an operation.
data HookConsent
  = ConsentApproved
  | ConsentDenied !Text
  | ConsentPrompt !Text
  deriving stock (Eq, Show, Generic)

-- | Execution context payload passed to a hook via stdin JSON.
data HookContext = HookContext
  { hcHookType  :: !HookType
  , hcToolName  :: !(Maybe Text)
  , hcToolArgs  :: !(Maybe Text)
  , hcSessionId :: !Text
  , hcModel     :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Execution result returned by a hook via stdout JSON or process exit.
data HookResult = HookResult
  { hrSuccess   :: !Bool
  , hrOutput    :: !Text
  , hrError     :: !(Maybe Text)
  , hrElapsedMs :: !Int
  } deriving stock (Eq, Show, Generic)

-- ----------------------------------------------------------------------------
-- Safe Zero-Aeson Encoders & Decoders
-- ----------------------------------------------------------------------------

encodeHookContext :: HookContext -> ByteString
encodeHookContext ctx =
  let htStr = case hcHookType ctx of
        PreToolCall  -> "pre_tool_call"
        PostToolCall -> "post_tool_call"
        PreTurn      -> "pre_turn"
        PostTurn     -> "post_turn"
      tName = maybe "null" (\t -> "\"" <> escapeJson t <> "\"") (hcToolName ctx)
      tArgs = maybe "null" (\a -> "\"" <> escapeJson a <> "\"") (hcToolArgs ctx)
  in "{\"hook_type\":\"" <> htStr
     <> "\",\"tool_name\":" <> tName
     <> ",\"tool_args\":" <> tArgs
     <> ",\"session_id\":\"" <> escapeJson (hcSessionId ctx)
     <> "\",\"model\":\"" <> escapeJson (hcModel ctx) <> "\"}"

encodeHookResult :: HookResult -> ByteString
encodeHookResult hr =
  let errStr = maybe "null" (\e -> "\"" <> escapeJson e <> "\"") (hrError hr)
      succStr = if hrSuccess hr then "true" else "false"
  in "{\"success\":" <> succStr
     <> ",\"output\":\"" <> escapeJson (hrOutput hr)
     <> "\",\"error\":" <> errStr
     <> ",\"elapsed_ms\":" <> BSC.pack (show (hrElapsedMs hr)) <> "}"

decodeHookResult :: ByteString -> Either Text HookResult
decodeHookResult bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  let succVal = case Map.lookup "success" fields of
        Just [TkBool b] -> b
        _               -> False
      outVal = case Map.lookup "output" fields of
        Just [TkString s] -> s
        _                 -> ""
      errVal = case Map.lookup "error" fields of
        Just [TkString s] -> Just s
        _                 -> Nothing
      msVal = case Map.lookup "elapsed_ms" fields of
        Just [TkInt n] -> fromIntegral n
        _              -> 0
  Right (HookResult succVal outVal errVal msVal)

escapeJson :: Text -> ByteString
escapeJson = TE.encodeUtf8 . T.pack . concatMap esc . T.unpack
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = [c]

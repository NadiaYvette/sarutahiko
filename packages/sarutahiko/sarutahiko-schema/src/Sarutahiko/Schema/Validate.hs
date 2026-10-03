{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Schema.Validate
-- Description : Offline JSON Schema validation and remote ref rejection
--
-- Implements Invariant 1 (No Network Fetch):
-- Schemas compile and validate strictly offline. Remote '$ref' resolution
-- (http/https URIs) is rejected with 'ErrRemoteSchemaRefUnsupported'.
module Sarutahiko.Schema.Validate
  ( -- * Validation
    validateSchema
  , validateJsonBytes

    -- * Errors
  , SchemaValidationError (..)
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)

import Kogaki.Wire.Json.Decode (extractObjectFields, splitValueTokens)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.Schema.Types (SchemaNode (..))

-- | Diagnostic error produced during schema validation.
--
-- @since 0.1.0.0
data SchemaValidationError
  = ErrMissingRequiredField !Text
  | ErrTypeMismatch !Text !Text
  | ErrNumberOutOfRange !Text !Int64
  | ErrRemoteSchemaRefUnsupported !Text
  | ErrInvalidSchema !Text
  deriving stock (Eq, Show, Generic)

-- | Validate raw JSON bytes against a 'SchemaNode'.
--
-- @since 0.1.0.0
validateJsonBytes :: SchemaNode -> ByteString -> Either SchemaValidationError ()
validateJsonBytes schema bs = case lexJsonEither bs of
  Left err  -> Left (ErrInvalidSchema err)
  Right tks -> validateSchema schema tks

-- | Validate a sequence of unboxed JSON tokens against a 'SchemaNode'.
--
-- @since 0.1.0.0
validateSchema :: SchemaNode -> [JsonToken] -> Either SchemaValidationError ()
validateSchema schema tokens = case schema of
  -- Invariant 1: No Network Fetch
  SchemaRef ref
    | "http://" `T.isPrefixOf` ref || "https://" `T.isPrefixOf` ref ->
        Left (ErrRemoteSchemaRefUnsupported ref)
    | otherwise ->
        Left (ErrInvalidSchema ("Unresolved local ref: " <> ref))

  SchemaAnnotated _ inner ->
    validateSchema inner tokens

  SchemaObject props requiredFields ->
    case extractObjectFields tokens of
      Left err -> Left (ErrInvalidSchema err)
      Right fieldMap -> do
        -- 1. Verify all required fields are present
        mapM_ (\req ->
          let reqBytes = TE.encodeUtf8 req
          in if Map.member reqBytes fieldMap
               then Right ()
               else Left (ErrMissingRequiredField req)
          ) requiredFields

        -- 2. Validate present fields against registered property schemas
        mapM_ (\(keyBytes, valTokens) ->
          let keyText = TE.decodeUtf8With TEE.lenientDecode keyBytes
          in case Map.lookup keyText props of
            Nothing -> Right () -- Open world: unmodeled properties pass validation
            Just propSchema -> validateSchema propSchema valTokens
          ) (Map.toList fieldMap)

  SchemaString _ ->
    case tokens of
      [TkString _] -> Right ()
      [TkKey _]    -> Right ()
      _            -> Left (ErrTypeMismatch "string" (tokenName tokens))

  SchemaInteger mMin mMax ->
    case tokens of
      [TkInt n] -> do
        case mMin of
          Just mn | n < mn -> Left (ErrNumberOutOfRange "below minimum" n)
          _                -> Right ()
        case mMax of
          Just mx | n > mx -> Left (ErrNumberOutOfRange "above maximum" n)
          _                -> Right ()
      _ -> Left (ErrTypeMismatch "integer" (tokenName tokens))

  SchemaNumber ->
    case tokens of
      [TkDouble _] -> Right ()
      [TkInt _]    -> Right ()
      _            -> Left (ErrTypeMismatch "number" (tokenName tokens))

  SchemaBoolean ->
    case tokens of
      [TkBool _] -> Right ()
      _          -> Left (ErrTypeMismatch "boolean" (tokenName tokens))

  SchemaArray elemSchema ->
    case tokens of
      (TkArrayOpen : rest) -> validateArrayItems elemSchema rest
      _                    -> Left (ErrTypeMismatch "array" (tokenName tokens))

-- | Validate elements of an array until 'TkArrayClose'.
validateArrayItems :: SchemaNode -> [JsonToken] -> Either SchemaValidationError ()
validateArrayItems _ [] = Left (ErrInvalidSchema "Unexpected EOF: unclosed array")
validateArrayItems _ (TkArrayClose : _) = Right ()
validateArrayItems elemSchema tokens = do
  case splitValueTokens tokens of
    Left err -> Left (ErrInvalidSchema err)
    Right (elemTokens, remainder) -> do
      validateSchema elemSchema elemTokens
      case remainder of
        (TkArrayClose : _) -> Right ()
        _                  -> validateArrayItems elemSchema remainder

-- | Human-readable token descriptor for error reporting.
tokenName :: [JsonToken] -> Text
tokenName [] = "empty"
tokenName (TkObjectOpen : _) = "object"
tokenName (TkArrayOpen : _)  = "array"
tokenName (TkString _ : _)   = "string"
tokenName (TkKey _ : _)      = "string"
tokenName (TkInt _ : _)      = "integer"
tokenName (TkDouble _ : _)   = "number"
tokenName (TkBool _ : _)     = "boolean"
tokenName (TkNull : _)       = "null"
tokenName (tok : _)          = T.pack (show tok)

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Kogaki.Wire.Json.Decode
-- Description : Row-native JSON decoding and canonical encoding
--
-- Implements Closure 1 (Anti-Aeson/Anti-Bloat Principle) and Closure 2
-- (Docrecords Introspection): direct decoding from unboxed token streams
-- into 'large-anon' 'Record Identity r' and 'WireEnvelope r' slots with
-- zero intermediate 'Value' tree allocations.
module Kogaki.Wire.Json.Decode
  ( -- * Single Token Decoding
    decodeJson

    -- * Field Decoders & Encoders
  , FromJsonField (..)
  , ToJsonField (..)

    -- * Row-Native Decoders
  , decodeJsonRow
  , decodeJsonRowEither
  , decodeJsonRowFromTokens
  , decodeJsonEnvelope

    -- * Canonical Encoders
  , encodeJsonRow
  , encodeJsonEnvelope
  , renderTokens

    -- * Token Slicing Helpers
  , extractObjectFields
  , splitValueTokens
  ) where

import Prelude hiding (sequenceA)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int64)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Proxy (Proxy (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE

import Data.Functor.Identity (Identity (..))
import Data.Record.Anon (AllFields, K (..), KnownFields, (:.:) (..))
import Data.Record.Anon.Advanced
  ( Record
  , cmap
  , collapse
  , czipWith
  , reifyKnownFields
  , sequenceA
  )

import Data.NonNull (NonNull, fromNullable, toNullable)
import Kogaki.Core.String
  ( LogicalString
  , fromByteString
  , fromText
  , toByteString
  )
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJson, lexJsonEither)
import Sarutahiko.Fields.Datum (SchemaVersion (..))
import Sarutahiko.Records.Envelope (RowKind (..), WireEnvelope (..))
import Sarutahiko.Records.HKD.TriState (TriState (..))

-- | Decode a single primitive JSON token from bytes.
--
-- @since 0.1.0.0
decodeJson :: ByteString -> Maybe JsonToken
decodeJson bs = case lexJson bs of
  [tok] -> Just tok
  _     -> Nothing

-- | Typeclass for decoding individual field types from a slice of tokens.
-- If the field was absent in the JSON object, 'decodeField' receives 'Nothing'.
--
-- @since 0.1.0.0
class FromJsonField a where
  decodeField :: Maybe [JsonToken] -> Either Text a

-- | Typeclass for canonically encoding individual field types to bytes.
-- Returning 'Nothing' indicates that the field should be omitted from the output
-- (e.g. for 'Absent' fields in 'TriState').
--
-- @since 0.1.0.0
class ToJsonField a where
  encodeField :: a -> Maybe ByteString

-- ----------------------------------------------------------------------------
-- Primitive FromJsonField & ToJsonField Instances
-- ----------------------------------------------------------------------------

instance FromJsonField Text where
  decodeField Nothing = Left "Missing required text field"
  decodeField (Just [TkString t]) = Right t
  decodeField (Just [TkKey k])    = Right (TE.decodeUtf8With TEE.lenientDecode k)
  decodeField (Just _)            = Left "TypeMismatch: expected String"

instance ToJsonField Text where
  encodeField t = Just ("\"" <> escapeJsonString (TE.encodeUtf8 t) <> "\"")

instance FromJsonField LogicalString where
  decodeField Nothing = Left "Missing required logical string field"
  decodeField (Just [TkString t]) = Right (fromText t)
  decodeField (Just [TkKey k]) =
    case fromByteString k of
      Left err -> Left (T.pack (show err))
      Right ls -> Right ls
  decodeField (Just _) = Left "TypeMismatch: expected String"

instance ToJsonField LogicalString where
  encodeField ls = Just ("\"" <> escapeJsonString (toByteString ls) <> "\"")

instance FromJsonField (NonNull LogicalString) where
  decodeField mToks = do
    ls <- decodeField mToks
    case fromNullable ls of
      Nothing -> Left "Expected non-empty logical string"
      Just nn -> Right nn

instance ToJsonField (NonNull LogicalString) where
  encodeField nn = encodeField (toNullable nn)

instance FromJsonField ByteString where
  decodeField Nothing = Left "Missing required bytestring field"
  decodeField (Just [TkKey k])    = Right k
  decodeField (Just [TkString t]) = Right (TE.encodeUtf8 t)
  decodeField (Just _)            = Left "TypeMismatch: expected ByteString"

instance ToJsonField ByteString where
  encodeField bs = Just ("\"" <> escapeJsonString bs <> "\"")

instance FromJsonField Int64 where
  decodeField Nothing = Left "Missing required integer field"
  decodeField (Just [TkInt n]) = Right n
  decodeField (Just _)         = Left "TypeMismatch: expected Integer"

instance ToJsonField Int64 where
  encodeField n = Just (BSC.pack (show n))

instance FromJsonField Int where
  decodeField Nothing = Left "Missing required int field"
  decodeField (Just [TkInt n]) = Right (fromIntegral n)
  decodeField (Just _)         = Left "TypeMismatch: expected Int"

instance ToJsonField Int where
  encodeField n = Just (BSC.pack (show n))

instance FromJsonField Double where
  decodeField Nothing = Left "Missing required double field"
  decodeField (Just [TkDouble d]) = Right d
  decodeField (Just [TkInt n])    = Right (fromIntegral n)
  decodeField (Just _)            = Left "TypeMismatch: expected Double"

instance ToJsonField Double where
  encodeField d = Just (BSC.pack (show d))

instance FromJsonField Bool where
  decodeField Nothing = Left "Missing required boolean field"
  decodeField (Just [TkBool b]) = Right b
  decodeField (Just _)          = Left "TypeMismatch: expected Bool"

instance ToJsonField Bool where
  encodeField True  = Just "true"
  encodeField False = Just "false"

instance (FromJsonField a) => FromJsonField (Maybe a) where
  decodeField Nothing            = Right Nothing
  decodeField (Just [TkNull])    = Right Nothing
  decodeField (Just ts)          = Just <$> decodeField (Just ts)

instance (ToJsonField a) => ToJsonField (Maybe a) where
  encodeField Nothing  = Just "null"
  encodeField (Just v) = encodeField v

-- | TriState preserves the absence vs explicit null distinction (CA1–CA3).
instance (FromJsonField a) => FromJsonField (TriState a) where
  decodeField Nothing         = Right Absent
  decodeField (Just [TkNull]) = Right PresentNull
  decodeField (Just ts)       = Present <$> decodeField (Just ts)

instance (ToJsonField a) => ToJsonField (TriState a) where
  encodeField Absent         = Nothing
  encodeField PresentNull    = Just "null"
  encodeField (Present v)    = encodeField v

instance (FromJsonField a) => FromJsonField [a] where
  decodeField Nothing = Left "Missing required array field"
  decodeField (Just (TkArrayOpen : rest)) = parseArrayElements rest
  decodeField (Just _) = Left "TypeMismatch: expected Array"

instance (ToJsonField a) => ToJsonField [a] where
  encodeField xs =
    let encodedItems = catMaybes (map encodeField xs)
    in Just ("[" <> BS.intercalate "," encodedItems <> "]")

-- | Parse array items until 'TkArrayClose'.
parseArrayElements :: (FromJsonField a) => [JsonToken] -> Either Text [a]
parseArrayElements [] = Left "Unexpected EOF in array: unclosed ']'"
parseArrayElements (TkArrayClose : _) = Right []
parseArrayElements tokens = do
  (elemTokens, remainder) <- splitValueTokens tokens
  val <- decodeField (Just elemTokens)
  case remainder of
    (TkArrayClose : _) -> Right [val]
    _                  -> (val :) <$> parseArrayElements remainder

-- ----------------------------------------------------------------------------
-- Nested Record Instance
-- ----------------------------------------------------------------------------

instance (KnownFields r, AllFields r FromJsonField) => FromJsonField (Record Identity r) where
  decodeField Nothing = Left "Missing required nested object field"
  decodeField (Just tokens) = decodeJsonRowFromTokens tokens

instance (KnownFields r, AllFields r ToJsonField) => ToJsonField (Record Identity r) where
  encodeField rec = Just (encodeJsonRow rec)

-- ----------------------------------------------------------------------------
-- Row Decoders
-- ----------------------------------------------------------------------------

-- | Decode a JSON byte stream directly into a 'Record Identity r' in linear time
-- with zero intermediate 'Value' tree.
--
-- @since 0.1.0.0
decodeJsonRow
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => ByteString
  -> Maybe (Record Identity r)
decodeJsonRow bs = case decodeJsonRowEither bs of
  Right rec -> Just rec
  Left _    -> Nothing

-- | Decode a JSON byte stream directly into a 'Record Identity r' with diagnostics.
--
-- @since 0.1.0.0
decodeJsonRowEither
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => ByteString
  -> Either Text (Record Identity r)
decodeJsonRowEither bs = do
  tokens <- lexJsonEither bs
  decodeJsonRowFromTokens tokens

-- | Decode a 'Record Identity r' from an already lexed token stream.
decodeJsonRowFromTokens
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => [JsonToken]
  -> Either Text (Record Identity r)
decodeJsonRowFromTokens tokens = do
  fieldMap <- extractObjectFields tokens
  let namesRecord = reifyKnownFields (Proxy @r)
      decRecord = cmap (Proxy @FromJsonField) (\(K name) ->
        let mTokens = Map.lookup (BSC.pack name) fieldMap
        in Comp (Identity <$> decodeField mTokens)
        ) namesRecord
  sequenceA decRecord

-- | Decode a JSON byte stream into a 'WireEnvelope (Record Identity r)', preserving unknown fields
-- and raw unparsed bytes per E3/E4 laws.
--
-- @since 0.1.0.0
decodeJsonEnvelope
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => SchemaVersion
  -> ByteString
  -> Either Text (WireEnvelope (Record Identity r))
decodeJsonEnvelope ver bs = do
  tokens <- lexJsonEither bs
  fieldMap <- extractObjectFields tokens
  let namesRecord = reifyKnownFields (Proxy @r)
      knownKeys = Set.fromList [ BSC.pack name | name <- collapse namesRecord ]
      decRecord = cmap (Proxy @FromJsonField) (\(K name) ->
        let mTokens = Map.lookup (BSC.pack name) fieldMap
        in Comp (Identity <$> decodeField mTokens)
        ) namesRecord
  payload <- sequenceA decRecord
  let unknowns =
        Map.fromList
          [ (TE.decodeUtf8With TEE.lenientDecode k, TE.decodeUtf8With TEE.lenientDecode (renderTokens ts))
          | (k, ts) <- Map.toList fieldMap
          , not (k `Set.member` knownKeys)
          ]
  Right WireEnvelope
    { envKind            = RowKindCommand
    , envSchemaVersion   = ver
    , envOriginalVersion = ver
    , envPayload         = payload
    , envRawBytes        = bs
    , envUnknownFields   = unknowns
    }

-- ----------------------------------------------------------------------------
-- Canonical Row Encoders (Law L4 & Anti-Bloat)
-- ----------------------------------------------------------------------------

-- | Canonically encode a 'Record Identity r' to compact JSON with keys sorted
-- in lexicographical code-point order.
--
-- @since 0.1.0.0
encodeJsonRow
  :: forall r. (KnownFields r, AllFields r ToJsonField)
  => Record Identity r
  -> ByteString
encodeJsonRow rec =
  let names = reifyKnownFields (Proxy @r)
      fieldsRecord = czipWith (Proxy @ToJsonField)
        (\(K name) (Identity val) -> K (fmap (BSC.pack name, ) (encodeField val)))
        names
        rec
      pairs = catMaybes (collapse fieldsRecord)
      sortedPairs = List.sortOn fst pairs
      renderedPairs = [ "\"" <> k <> "\":" <> v | (k, v) <- sortedPairs ]
  in "{" <> BS.intercalate "," renderedPairs <> "}"

-- | Canonically encode a 'WireEnvelope (Record Identity r)' to compact JSON.
--
-- @since 0.1.0.0
encodeJsonEnvelope
  :: forall r. (KnownFields r, AllFields r ToJsonField)
  => WireEnvelope (Record Identity r)
  -> ByteString
encodeJsonEnvelope env = encodeJsonRow (envPayload env)

-- ----------------------------------------------------------------------------
-- Token Slicing & Object Splitting
-- ----------------------------------------------------------------------------

-- | Extract key-value token slices from an object token stream.
extractObjectFields :: [JsonToken] -> Either Text (Map.Map ByteString [JsonToken])
extractObjectFields [] = Left "Unexpected EOF: expected object"
extractObjectFields (TkObjectOpen : rest) = go rest Map.empty
  where
    go [] _ = Left "Unexpected EOF: unclosed object"
    go (TkObjectClose : _) !acc = Right acc
    go (TkKey k : afterKey) !acc = do
      (valTokens, remainder) <- splitValueTokens afterKey
      go remainder (Map.insert k valTokens acc)
    go (tok : _) _ = Left ("Expected TkKey or TkObjectClose in object, got: " <> T.pack (show tok))
extractObjectFields (tok : _) = Left ("Expected TkObjectOpen, got: " <> T.pack (show tok))

-- | Split the first complete JSON value from the head of a token stream,
-- returning the value's tokens and the remaining tokens.
splitValueTokens :: [JsonToken] -> Either Text ([JsonToken], [JsonToken])
splitValueTokens [] = Left "Unexpected EOF: expected value"
splitValueTokens (TkObjectOpen : rest) = scanBalanced TkObjectOpen TkObjectClose rest [TkObjectOpen] 1
splitValueTokens (TkArrayOpen : rest)  = scanBalanced TkArrayOpen TkArrayClose rest [TkArrayOpen] 1
splitValueTokens (tok : rest)          = Right ([tok], rest)

scanBalanced
  :: JsonToken
  -> JsonToken
  -> [JsonToken]
  -> [JsonToken]
  -> Int
  -> Either Text ([JsonToken], [JsonToken])
scanBalanced _ _ [] _ _ = Left "Unexpected EOF while scanning nested container"
scanBalanced openTok closeTok (tok : rest) !acc !depth
  | tok == openTok  = scanBalanced openTok closeTok rest (tok : acc) (depth + 1)
  | tok == closeTok =
      if depth == 1
        then Right (reverse (tok : acc), rest)
        else scanBalanced openTok closeTok rest (tok : acc) (depth - 1)
  | otherwise = scanBalanced openTok closeTok rest (tok : acc) depth

-- | Render a sequence of tokens back to canonical JSON bytes.
renderTokens :: [JsonToken] -> ByteString
renderTokens tokens = fst (renderValue tokens)
  where
    renderValue [] = ("", [])
    renderValue (TkObjectOpen : rest) =
      let (pairs, afterClose) = renderObjectPairs rest []
      in ("{" <> BS.intercalate "," pairs <> "}", afterClose)
    renderValue (TkArrayOpen : rest) =
      let (elems, afterClose) = renderArrayElems rest []
      in ("[" <> BS.intercalate "," elems <> "]", afterClose)
    renderValue (TkString t : rest) = ("\"" <> escapeJsonString (TE.encodeUtf8 t) <> "\"", rest)
    renderValue (TkInt n : rest) = (BSC.pack (show n), rest)
    renderValue (TkDouble d : rest) = (BSC.pack (show d), rest)
    renderValue (TkBool True : rest) = ("true", rest)
    renderValue (TkBool False : rest) = ("false", rest)
    renderValue (TkNull : rest) = ("null", rest)
    renderValue (tok : rest) = (BSC.pack (show tok), rest)

    renderObjectPairs [] acc = (reverse acc, [])
    renderObjectPairs (TkObjectClose : rest) acc = (reverse acc, rest)
    renderObjectPairs (TkKey k : afterKey) acc =
      let (valBytes, afterVal) = renderValue afterKey
          pair = "\"" <> escapeJsonString k <> "\":" <> valBytes
      in renderObjectPairs afterVal (pair : acc)
    renderObjectPairs (_ : rest) acc = renderObjectPairs rest acc

    renderArrayElems [] acc = (reverse acc, [])
    renderArrayElems (TkArrayClose : rest) acc = (reverse acc, rest)
    renderArrayElems tks acc =
      let (elemBytes, afterElem) = renderValue tks
      in renderArrayElems afterElem (elemBytes : acc)

-- | Escape characters in string bytes according to JSON spec.
escapeJsonString :: ByteString -> ByteString
escapeJsonString bs = BSC.concatMap escapeChar bs
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = BSC.singleton c

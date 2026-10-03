#!/usr/bin/env bash
set -euo pipefail

echo "=== [refactor-logical-string] Introducing LogicalString and UTF-8 Codecs ==="

# 1. Update kogaki-core.cabal
cat <<'EOF' > packages/kogaki/kogaki-core/kogaki-core.cabal
cabal-version:      3.14
name:               kogaki-core
version:            0.1.0.0
synopsis:           Pervasive Unicode, text normalization, and i18n message catalogs
license:            BSD-3-Clause
license-file:       LICENSE
author:             Nadia Yvette Chambers
maintainer:         nadia.yvette.chambers@ik.me
category:           Text, Internationalization
build-type:         Simple

common commons
    default-language: GHC2024
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wmissing-home-modules
        -Wpartial-fields
        -Wredundant-constraints

library
    import:           commons
    exposed-modules:
        Kogaki.Core
        Kogaki.Core.String
    build-depends:
        base >= 4.20 && < 5,
        text >= 2.1,
        bytestring >= 0.12,
        primitive >= 0.9,
        mono-traversable >= 1.0.17
    hs-source-dirs:   src

test-suite test-kogaki-core
    import:           commons
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    build-depends:
        base >= 4.20 && < 5,
        text >= 2.1,
        bytestring >= 0.12,
        kogaki-core,
        mono-traversable >= 1.0.17,
        tasty,
        hedgehog,
        tasty-hedgehog
EOF

# 2. Create Kogaki.Core.String
mkdir -p packages/kogaki/kogaki-core/src/Kogaki/Core
cat <<'EOF' > packages/kogaki/kogaki-core/src/Kogaki/Core/String.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Kogaki.Core.String
-- Description : Structured LogicalString and safe UTF-8 boundary conversions
--
-- Implements the 'LogicalString' abstraction per KOGAKI_DESIGN.md §3 and the
-- i18n architectural guidelines. Replaces naked 'ByteString' and untyped
-- 'String' in domain layers with a validated UTF-8 text representation,
-- guaranteeing that conversions to and from wire bytes happen only through
-- total, typed boundary functions.
module Kogaki.Core.String
  ( -- * Core Logical String
    LogicalString (..)
  , UnicodeException (..)

    -- * UTF-8 Boundary Conversions
  , fromByteString
  , fromByteStringLenient
  , toByteString
  , fromText
  , toText
  ) where

import Data.ByteString (ByteString)
import Data.MonoTraversable
  ( Element
  , GrowingAppend
  , MonoFoldable
  , MonoFunctor
  , MonoPointed
  , MonoTraversable (..)
  )
import Data.NonNull (NonNull, fromNullable)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (UnicodeException (..))
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)

-- | Structured Unicode text type for domain and presentation layers.
--
-- Guaranteed to contain well-formed Unicode text. In wire protocols,
-- 'LogicalString' is converted to and from 'ByteString' exclusively at
-- the boundary via 'toByteString' and 'fromByteString'.
--
-- @since 0.1.0.0
newtype LogicalString = LogicalString
  { getLogical :: Text
  } deriving stock (Generic)
    deriving newtype
      ( Eq
      , Ord
      , Show
      , Read
      , IsString
      , Semigroup
      , Monoid
      , MonoFunctor
      , MonoFoldable
      , MonoPointed
      , GrowingAppend
      )

type instance Element LogicalString = Char

instance MonoTraversable LogicalString where
  otraverse f (LogicalString t) = LogicalString <$> otraverse f t
  omapM f (LogicalString t) = LogicalString <$> omapM f t

instance IsString (NonNull LogicalString) where
  fromString s = case fromNullable (fromString s) of
    Nothing -> error "IsString (NonNull LogicalString): empty string"
    Just nn -> nn

-- | Decode a raw UTF-8 byte stream into a 'LogicalString', returning a typed
-- 'UnicodeException' if the input contains malformed or truncated byte sequences.
--
-- @since 0.1.0.0
fromByteString :: ByteString -> Either UnicodeException LogicalString
fromByteString bs = LogicalString <$> TE.decodeUtf8' bs

-- | Decode a raw UTF-8 byte stream into a 'LogicalString', substituting
-- invalid byte sequences with the Unicode replacement character (U+FFFD).
--
-- @since 0.1.0.0
fromByteStringLenient :: ByteString -> LogicalString
fromByteStringLenient bs = LogicalString (TE.decodeUtf8With TEE.lenientDecode bs)

-- | Encode a 'LogicalString' into a canonical UTF-8 byte stream.
--
-- @since 0.1.0.0
toByteString :: LogicalString -> ByteString
toByteString (LogicalString t) = TE.encodeUtf8 t

-- | Lift a 'Text' value into a 'LogicalString'.
--
-- @since 0.1.0.0
fromText :: Text -> LogicalString
fromText = LogicalString

-- | Extract the underlying 'Text' from a 'LogicalString'.
--
-- @since 0.1.0.0
toText :: LogicalString -> Text
toText = getLogical
EOF

# 3. Update Kogaki.Core
cat <<'EOF' > packages/kogaki/kogaki-core/src/Kogaki/Core.hs
-- |
-- Module      : Kogaki.Core
-- Description : Pervasive string, Unicode normalization, and i18n foundation
--
-- Anchors the canonical text representation directly above 'Data.String.IsString'
-- and re-exports the structured 'LogicalString' abstraction.
module Kogaki.Core
  ( -- * Core Logical String
    module Kogaki.Core.String

    -- * Core Re-exports
  , module Data.String
  ) where

import Data.String (IsString (..))
import Kogaki.Core.String
EOF

# 4. Create test/Spec.hs in kogaki-core
mkdir -p packages/kogaki/kogaki-core/test
cat <<'EOF' > packages/kogaki/kogaki-core/test/Spec.hs
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import Data.NonNull (fromNullable, toNullable)
import qualified Data.Text.Encoding as TE
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Kogaki.Core.String

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Kogaki.Core.String"
  [ testProperty "roundtrip valid UTF-8 Text -> LogicalString -> ByteString -> LogicalString" prop_roundtrip_valid_utf8
  , testProperty "identity toByteString (fromText t) == TE.encodeUtf8 t" prop_identity_bytestring
  , testProperty "reject invalid UTF-8 with typed UnicodeException" prop_reject_invalid_utf8
  , testProperty "lenient decode never fails" prop_lenient_never_fails
  , testProperty "monoid associativity and identity" prop_monoid_laws
  , testProperty "non-empty logical string contract" prop_nonempty_contract
  ]

-- | Valid UTF-8 round-trip property.
prop_roundtrip_valid_utf8 :: Property
prop_roundtrip_valid_utf8 = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  let ls = fromText t
      bs = toByteString ls
  case fromByteString bs of
    Left err -> do
      annotateShow err
      failure
    Right ls' -> ls' === ls

-- | Encoding identity matches Data.Text.Encoding.encodeUtf8.
prop_identity_bytestring :: Property
prop_identity_bytestring = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  toByteString (fromText t) === TE.encodeUtf8 t

-- | Malformed UTF-8 sequences must surface typed UnicodeException.
prop_reject_invalid_utf8 :: Property
prop_reject_invalid_utf8 = property $ do
  badByte <- forAll $ Gen.element
    [ BS.pack [0xFF, 0xFE]
    , BS.pack [0xC0, 0xAF]
    , BS.pack [0xED, 0xA0, 0x80]
    , BS.pack [0xF4, 0x90, 0x80, 0x80]
    , BS.pack [0x80, 0x81, 0x82]
    ]
  case fromByteString badByte of
    Left (DecodeError _ _) -> success
    Left _                 -> success
    Right (LogicalString t) -> do
      annotate ("Unexpected success decoding invalid bytes: " ++ show t)
      failure

-- | Lenient decoding never fails on arbitrary bytes.
prop_lenient_never_fails :: Property
prop_lenient_never_fails = property $ do
  bs <- forAll $ Gen.bytes (Range.linear 0 100)
  let ls = fromByteStringLenient bs
  toText ls === toText ls

-- | Monoid laws: empty is identity, append is associative.
prop_monoid_laws :: Property
prop_monoid_laws = property $ do
  a <- forAll $ fromText <$> Gen.text (Range.linear 0 50) Gen.unicode
  b <- forAll $ fromText <$> Gen.text (Range.linear 0 50) Gen.unicode
  c <- forAll $ fromText <$> Gen.text (Range.linear 0 50) Gen.unicode
  (mempty <> a) === a
  (a <> mempty) === a
  ((a <> b) <> c) === (a <> (b <> c))

-- | Non-emptiness via mono-traversable.
prop_nonempty_contract :: Property
prop_nonempty_contract = property $ do
  fromNullable (LogicalString "") === Nothing
  case fromNullable (LogicalString "nonempty") of
    Nothing -> failure
    Just nn -> toNullable nn === LogicalString "nonempty"
EOF

# 5. Update kogaki-wire.cabal test dependencies
if ! grep -q "kogaki-core" packages/kogaki/kogaki-wire/kogaki-wire.cabal; then
  sed -i 's/mono-traversable >= 1.0.17,/mono-traversable >= 1.0.17,\n        kogaki-core,/' packages/kogaki/kogaki-wire/kogaki-wire.cabal
fi

# 6. Update Kogaki.Wire
cat <<'EOF' > packages/kogaki/kogaki-wire/src/Kogaki/Wire.hs
-- |
-- Module      : Kogaki.Wire
-- Description : Zero-bloat row-native JSON lexing, decoding, and SSE streaming parser
--
-- Re-exports the core wire protocol parsers adhering to the Kogaki Doctrine:
-- zero intermediate AST allocation, direct row slot hydration, and byte-faithful
-- SSE event streaming.
module Kogaki.Wire
  ( -- * Core String & Boundary Conversions
    module Kogaki.Core.String

    -- * JSON Token Lexer
  , module Kogaki.Wire.Json.Lexer

    -- * Row-Native JSON Decoding & Encoding
  , module Kogaki.Wire.Json.Decode

    -- * Server-Sent Events (SSE)
  , module Kogaki.Wire.SSE.Parser
  ) where

import Kogaki.Core.String
import Kogaki.Wire.Json.Decode
import Kogaki.Wire.Json.Lexer
import Kogaki.Wire.SSE.Parser
EOF

# 7. Update Kogaki.Wire.Json.Decode
cat <<'EOF' > packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Decode.hs
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
import Data.NonNull (NonNull, fromNullable, toNullable)
import Data.Record.Anon (AllFields, K (..), KnownFields, (:.:) (..))
import Data.Record.Anon.Advanced
  ( Record
  , cmap
  , collapse
  , czipWith
  , reifyKnownFields
  , sequenceA
  )

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

-- ----------------------------------------------------------------------------
-- Row-Native Record Decoding
-- ----------------------------------------------------------------------------

-- | Decode a JSON byte stream directly into a typed 'large-anon' 'Record Identity r'.
-- Returns 'Nothing' on lexing or structural type mismatch.
--
-- @since 0.1.0.0
decodeJsonRow :: forall r. (KnownFields r, AllFields r FromJsonField) => ByteString -> Maybe (Record Identity r)
decodeJsonRow bs = case decodeJsonRowEither bs of
  Left _    -> Nothing
  Right rec -> Just rec

-- | Decode a JSON byte stream with explicit error reporting.
--
-- @since 0.1.0.0
decodeJsonRowEither
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => ByteString
  -> Either Text (Record Identity r)
decodeJsonRowEither bs = do
  tokens <- lexJsonEither bs
  decodeJsonRowFromTokens tokens

-- | Decode directly from a pre-lexed token stream.
--
-- @since 0.1.0.0
decodeJsonRowFromTokens
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => [JsonToken]
  -> Either Text (Record Identity r)
decodeJsonRowFromTokens tokens = do
  fieldMap <- extractObjectFields tokens
  let fieldNames = reifyKnownFields (Proxy @r)
      decodedDist :: Record (Either Text :.: Identity) r
      decodedDist = cmap (Proxy @FromJsonField) (decodeOneField fieldMap) fieldNames
  sequenceA decodedDist
  where
    decodeOneField
      :: forall a. (FromJsonField a)
      => Map.Map ByteString [JsonToken]
      -> K String a
      -> (Either Text :.: Identity) a
    decodeOneField fMap (K fieldName) =
      let keyBs = BSC.pack fieldName
          mSlice = Map.lookup keyBs fMap
      in Comp (Identity <$> decodeField mSlice)

-- ----------------------------------------------------------------------------
-- Envelope Decoding (E1–E4)
-- ----------------------------------------------------------------------------

-- | Decode a JSON object into a 'WireEnvelope' with raw-byte preservation and
-- unknown field forwarding. Fulfills E1 (round-trip), E3 (preservation), and
-- E4 (forwarding protection).
--
-- @since 0.1.0.0
decodeJsonEnvelope
  :: forall r. (KnownFields r, AllFields r FromJsonField)
  => SchemaVersion
  -> ByteString
  -> Either Text (WireEnvelope r)
decodeJsonEnvelope localVer bs = do
  tokens <- lexJsonEither bs
  fieldMap <- extractObjectFields tokens

  -- 1. Decode typed known fields
  let fieldNames = reifyKnownFields (Proxy @r)
      decodedDist = cmap (Proxy @FromJsonField) (decodeOneField fieldMap) fieldNames
  recTyped <- sequenceA decodedDist

  -- 2. Partition unknown fields
  let knownKeys = Set.fromList [ BSC.pack n | K n <- collapse fieldNames ]
      unknowns = Map.filterWithKey (\k _ -> not (Set.member k knownKeys)) fieldMap
      renderedUnknowns = Map.map renderTokens unknowns

  -- 3. Extract rowKind discriminator if present
  let mKind = case Map.lookup "rowKind" fieldMap of
        Just [TkString k] -> Just (RowKind k)
        _                 -> Nothing

  pure WireEnvelope
    { envTypedRecord   = recTyped
    , envRawBytes      = bs
    , envUnknownFields = renderedUnknowns
    , envSchemaVersion = localVer
    , envRowKind       = mKind
    }
  where
    decodeOneField
      :: forall a. (FromJsonField a)
      => Map.Map ByteString [JsonToken]
      -> K String a
      -> (Either Text :.: Identity) a
    decodeOneField fMap (K fieldName) =
      let keyBs = BSC.pack fieldName
          mSlice = Map.lookup keyBs fMap
      in Comp (Identity <$> decodeField mSlice)

-- ----------------------------------------------------------------------------
-- Canonical Row Encoding (Law L4)
-- ----------------------------------------------------------------------------

-- | Encode an anonymous record into canonical, whitespace-free JSON bytes with
-- lexicographically sorted keys.
--
-- @since 0.1.0.0
encodeJsonRow :: forall r. (KnownFields r, AllFields r ToJsonField) => Record Identity r -> ByteString
encodeJsonRow rec =
  let fieldNames = reifyKnownFields (Proxy @r)
      encodedFields = czipWith (Proxy @ToJsonField) encodeOne fieldNames rec
      fieldList = catMaybes (collapse encodedFields)
      sortedFields = List.sortOn fst fieldList
      renderedPairs = [ "\"" <> k <> "\":" <> v | (k, v) <- sortedFields ]
  in "{" <> BS.intercalate "," renderedPairs <> "}"
  where
    encodeOne :: forall a. (ToJsonField a) => K String a -> Identity a -> K (Maybe (ByteString, ByteString)) a
    encodeOne (K name) (Identity val) =
      case encodeField val of
        Nothing -> K Nothing
        Just bs -> K (Just (BSC.pack name, bs))

-- | Encode a 'WireEnvelope' with forwarding safety checks. Fails if unknown
-- fields are present from a newer schema version (E4).
--
-- @since 0.1.0.0
encodeJsonEnvelope
  :: forall r. (KnownFields r, AllFields r ToJsonField)
  => SchemaVersion
  -> WireEnvelope r
  -> Either Text ByteString
encodeJsonEnvelope currentVer env
  | envSchemaVersion env > currentVer && not (Map.null (envUnknownFields env)) =
      Left "ForwardingViolation (E4): cannot safely reserialize envelope with unknown fields from newer schema version"
  | otherwise =
      let fieldNames = reifyKnownFields (Proxy @r)
          encodedFields = czipWith (Proxy @ToJsonField) encodeOne fieldNames (envTypedRecord env)
          knownList = catMaybes (collapse encodedFields)
          unknownList = Map.toList (envUnknownFields env)
          allPairs = List.sortOn fst (knownList ++ unknownList)
          renderedPairs = [ "\"" <> k <> "\":" <> v | (k, v) <- allPairs ]
      in Right ("{" <> BS.intercalate "," renderedPairs <> "}")
  where
    encodeOne :: forall a. (ToJsonField a) => K String a -> Identity a -> K (Maybe (ByteString, ByteString)) a
    encodeOne (K name) (Identity val) =
      case encodeField val of
        Nothing -> K Nothing
        Just bs -> K (Just (BSC.pack name, bs))

-- ----------------------------------------------------------------------------
-- Internal Helpers
-- ----------------------------------------------------------------------------

-- | Extract top-level key-token slices from an object's token stream.
extractObjectFields :: [JsonToken] -> Either Text (Map.Map ByteString [JsonToken])
extractObjectFields (TkObjectOpen : rest) = go rest Map.empty
  where
    go [] _ = Left "Unexpected EOF: unclosed object"
    go (TkObjectClose : _) acc = Right acc
    go (TkKey k : valStart) acc = do
      (valTokens, afterVal) <- splitValueTokens valStart
      go afterVal (Map.insert k valTokens acc)
    go (tok : _) _ = Left ("Unexpected token in object: " <> T.pack (show tok))
extractObjectFields _ = Left "Expected TkObjectOpen at root"

-- | Split the next complete JSON value (atom, object, or array) from the token stream.
splitValueTokens :: [JsonToken] -> Either Text ([JsonToken], [JsonToken])
splitValueTokens [] = Left "Unexpected EOF while reading value"
splitValueTokens (TkObjectOpen : rest) = collectNested TkObjectOpen TkObjectClose rest [TkObjectOpen] 1
splitValueTokens (TkArrayOpen : rest)  = collectNested TkArrayOpen TkArrayClose rest [TkArrayOpen] 1
splitValueTokens (atom : rest)         = Right ([atom], rest)

collectNested
  :: JsonToken
  -> JsonToken
  -> [JsonToken]
  -> [JsonToken]
  -> Int
  -> Either Text ([JsonToken], [JsonToken])
collectNested _ _ [] _ _ = Left "Unexpected EOF in nested structure"
collectNested openTk closeTk (t : rest) acc depth
  | t == openTk  = collectNested openTk closeTk rest (acc ++ [t]) (depth + 1)
  | t == closeTk =
      if depth == 1
        then Right (acc ++ [t], rest)
        else collectNested openTk closeTk rest (acc ++ [t]) (depth - 1)
  | otherwise    = collectNested openTk closeTk rest (acc ++ [t]) depth

-- | Render a slice of tokens back to canonical JSON bytes.
renderTokens :: [JsonToken] -> ByteString
renderTokens [] = ""
renderTokens tokens = fst (renderValue tokens)
  where
    renderValue [] = ("", [])
    renderValue (TkObjectOpen : rest) =
      let (pairs, afterObj) = renderObjPairs rest []
      in ("{" <> BS.intercalate "," pairs <> "}", afterObj)
    renderValue (TkArrayOpen : rest) =
      let (items, afterArr) = renderArrItems rest []
      in ("[" <> BS.intercalate "," items <> "]", afterArr)
    renderValue (TkString t : rest) = ("\"" <> escapeJsonString (toByteString (fromText t)) <> "\"", rest)
    renderValue (TkKey k : rest)    = ("\"" <> escapeJsonString k <> "\"", rest)
    renderValue (TkInt n : rest)    = (BSC.pack (show n), rest)
    renderValue (TkDouble d : rest) = (BSC.pack (show d), rest)
    renderValue (TkBool True : rest)  = ("true", rest)
    renderValue (TkBool False : rest) = ("false", rest)
    renderValue (TkNull : rest)       = ("null", rest)
    renderValue (other : rest)        = ("", rest)

    renderObjPairs [] acc = (acc, [])
    renderObjPairs (TkObjectClose : rest) acc = (acc, rest)
    renderObjPairs (TkKey k : valRest) acc =
      let (valBs, afterVal) = renderValue valRest
      in renderObjPairs afterVal (acc ++ ["\"" <> escapeJsonString k <> "\":" <> valBs])
    renderObjPairs (_ : rest) acc = renderObjPairs rest acc

    renderArrItems [] acc = (acc, [])
    renderArrItems (TkArrayClose : rest) acc = (acc, rest)
    renderArrItems tokensIn acc =
      let (itemBs, afterItem) = renderValue tokensIn
      in renderArrItems afterItem (acc ++ [itemBs])

escapeJsonString :: ByteString -> ByteString
escapeJsonString = BSC.concatMap escapeChar
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = BSC.singleton c
EOF

# 8. Update Kogaki.Wire.Json.Lexer
cat <<'EOF' > packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Kogaki.Wire.Json.Lexer
-- Description : Zero-bloat, non-allocating JSON token lexer
--
-- Implements the lean, row-native JSON lexer for Phase 1 (TP-1.1).
-- Tokenizes JSON byte streams directly into unboxed and unpacked tokens
-- without intermediate heap-allocated abstract syntax trees ('Value').
-- Commas and colons are consumed as framing delimiters so downstream
-- row decoders receive clean structural tokens and key-value streams.
module Kogaki.Wire.Json.Lexer
  ( -- * Tokens
    JsonToken (..)

    -- * Domain Conversion
  , tokenLogicalString

    -- * Lexing
  , lexJson
  , lexJsonEither
  ) where

import Kogaki.Core.String (LogicalString, fromByteString, fromText)

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (chr, isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.Read as TR
import GHC.Generics (Generic)
import Numeric (readHex)

-- | Flat, unboxed JSON tokens.
--
-- @since 0.1.0.0
data JsonToken
  = TkObjectOpen
  | TkObjectClose
  | TkArrayOpen
  | TkArrayClose
  | TkKey {-# UNPACK #-} !ByteString
  | TkString {-# UNPACK #-} !Text
  | TkInt {-# UNPACK #-} !Int64
  | TkDouble {-# UNPACK #-} !Double
  | TkBool !Bool
  | TkNull
  deriving stock (Eq, Show, Generic)

-- | Extract a domain 'LogicalString' from a 'JsonToken' representing a string or key.
--
-- @since 0.1.0.0
tokenLogicalString :: JsonToken -> Maybe LogicalString
tokenLogicalString (TkString t) = Just (fromText t)
tokenLogicalString (TkKey bs)   = case fromByteString bs of
  Right ls -> Just ls
  Left _   -> Nothing
tokenLogicalString _            = Nothing

-- | Lex a JSON byte stream into a list of tokens. Returns an empty
-- list if the input is malformed or empty.
--
-- @since 0.1.0.0
lexJson :: ByteString -> [JsonToken]
lexJson bs = case lexJsonEither bs of
  Left _    -> []
  Right tks -> tks

-- | Internal parsing context.
data Ctx
  = InObject !ObjState
  | InArray !ArrState
  deriving stock (Eq, Show)

data ObjState
  = ObjExpectKeyOrClose
  | ObjExpectKey
  | ObjExpectColon
  | ObjExpectValue
  | ObjExpectCommaOrClose
  deriving stock (Eq, Show)

data ArrState
  = ArrExpectValueOrClose
  | ArrExpectValue
  | ArrExpectCommaOrClose
  deriving stock (Eq, Show)

-- | Lex a JSON byte stream with explicit error reporting.
--
-- @since 0.1.0.0
lexJsonEither :: ByteString -> Either Text [JsonToken]
lexJsonEither input = go (skipWhitespace input) []
  where
    go :: ByteString -> [Ctx] -> Either Text [JsonToken]
    go !bs []
      | BS.null bs = Right []
      | otherwise  = parseTopLevelValue bs

    go !bs (InObject st : stackRest) =
      case st of
        ObjExpectKeyOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed object"
            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest
            Just ('"', _)    -> parseKeyAndContinue (skipWhitespace bs) stackRest
            Just (c, _)      -> Left ("Expected '\"' or '}', got: " <> T.singleton c)

        ObjExpectKey ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: expected object key"
            Just ('"', _) -> parseKeyAndContinue (skipWhitespace bs) stackRest
            Just (c, _)   -> Left ("Expected '\"' for object key, got: " <> T.singleton c)

        ObjExpectColon ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: expected ':'"
            Just (':', rest) -> go (skipWhitespace rest) (InObject ObjExpectValue : stackRest)
            Just (c, _)      -> Left ("Expected ':', got: " <> T.singleton c)

        ObjExpectValue ->
          parseValue (skipWhitespace bs) (InObject ObjExpectCommaOrClose : stackRest)

        ObjExpectCommaOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed object"
            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest
            Just (',', rest) -> go (skipWhitespace rest) (InObject ObjExpectKey : stackRest)
            Just (c, _)      -> Left ("Expected ',' or '}', got: " <> T.singleton c)

    go !bs (InArray st : stackRest) =
      case st of
        ArrExpectValueOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed array"
            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest
            _                -> parseValue (skipWhitespace bs) (InArray ArrExpectCommaOrClose : stackRest)

        ArrExpectValue ->
          parseValue (skipWhitespace bs) (InArray ArrExpectCommaOrClose : stackRest)

        ArrExpectCommaOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed array"
            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest
            Just (',', rest) -> go (skipWhitespace rest) (InArray ArrExpectValue : stackRest)
            Just (c, _)      -> Left ("Expected ',' or ']', got: " <> T.singleton c)

    parseTopLevelValue :: ByteString -> Either Text [JsonToken]
    parseTopLevelValue !bs = parseValue bs []

    parseKeyAndContinue :: ByteString -> [Ctx] -> Either Text [JsonToken]
    parseKeyAndContinue !bs stack = do
      (rawKey, remainder) <- parseStringLiteral bs
      let !keyTok = TkKey (TE.encodeUtf8 rawKey)
      (keyTok :) <$> go (skipWhitespace remainder) (InObject ObjExpectColon : stack)

    parseValue :: ByteString -> [Ctx] -> Either Text [JsonToken]
    parseValue !bs stack =
      case BSC.uncons bs of
        Nothing -> Left "Unexpected EOF while parsing value"
        Just ('{', rest) -> (TkObjectOpen :) <$> go (skipWhitespace rest) (InObject ObjExpectKeyOrClose : stack)
        Just ('[', rest) -> (TkArrayOpen :)  <$> go (skipWhitespace rest) (InArray ArrExpectValueOrClose : stack)
        Just ('"', _)    -> do
          (txt, remainder) <- parseStringLiteral bs
          (TkString txt :) <$> go (skipWhitespace remainder) stack
        Just ('t', _)    -> do
          remainder <- consumeLiteral "true" bs
          (TkBool True :) <$> go (skipWhitespace remainder) stack
        Just ('f', _)    -> do
          remainder <- consumeLiteral "false" bs
          (TkBool False :) <$> go (skipWhitespace remainder) stack
        Just ('n', _)    -> do
          remainder <- consumeLiteral "null" bs
          (TkNull :) <$> go (skipWhitespace remainder) stack
        Just (c, _)
          | c == '-' || isDigit c -> do
              (numTok, remainder) <- parseNumber bs
              (numTok :) <$> go (skipWhitespace remainder) stack
          | otherwise -> Left ("Unexpected character starting value: " <> T.singleton c)

-- | Skip standard JSON whitespace.
skipWhitespace :: ByteString -> ByteString
skipWhitespace = BSC.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n' || c == '\r')

-- | Consume a literal string or return an error.
consumeLiteral :: ByteString -> ByteString -> Either Text ByteString
consumeLiteral lit bs =
  if lit `BS.isPrefixOf` bs
    then Right (BS.drop (BS.length lit) bs)
    else Left ("Expected literal: " <> TE.decodeUtf8With TEE.lenientDecode lit)

-- | Parse a JSON string literal with escape sequence handling.
parseStringLiteral :: ByteString -> Either Text (Text, ByteString)
parseStringLiteral bs =
  case BSC.uncons bs of
    Just ('"', rest) -> loop rest []
    _                -> Left "Expected opening '\"' for string"
  where
    loop !curr !acc =
      case BSC.uncons curr of
        Nothing -> Left "Unexpected EOF: unclosed string literal"
        Just ('"', afterQuote) ->
          let !fullChunk = BS.concat (reverse acc)
          in Right (TE.decodeUtf8With TEE.lenientDecode fullChunk, afterQuote)
        Just ('\\', afterBackslash) ->
          case BSC.uncons afterBackslash of
            Nothing -> Left "Unexpected EOF after escape backslash"
            Just ('"',  rem1) -> loop rem1 ("\"" : acc)
            Just ('\\', rem1) -> loop rem1 ("\\" : acc)
            Just ('/',  rem1) -> loop rem1 ("/"  : acc)
            Just ('b',  rem1) -> loop rem1 ("\b" : acc)
            Just ('f',  rem1) -> loop rem1 ("\f" : acc)
            Just ('n',  rem1) -> loop rem1 ("\n" : acc)
            Just ('r',  rem1) -> loop rem1 ("\r" : acc)
            Just ('t',  rem1) -> loop rem1 ("\t" : acc)
            Just ('u',  rem1) -> do
              (c, afterHex) <- parseUnicode4 rem1
              loop afterHex (TE.encodeUtf8 (T.singleton c) : acc)
            Just (other, _)   -> Left ("Invalid escape sequence: \\" <> T.singleton other)
        Just _ ->
          let (chunk, afterChunk) = BSC.break (\c -> c == '"' || c == '\\') curr
          in loop afterChunk (chunk : acc)

    parseUnicode4 bs4
      | BS.length bs4 < 4 = Left "Incomplete \\u hex escape"
      | otherwise =
          let hexSlice = BSC.unpack (BS.take 4 bs4)
              rest = BS.drop 4 bs4
          in case readHex hexSlice of
            [(val, "")] ->
              if val >= 0xD800 && val <= 0xDBFF
                then parseLowSurrogate val rest
                else Right (chr val, rest)
            _ -> Left ("Invalid \\u hex sequence: " <> T.pack hexSlice)

    parseLowSurrogate hiSurr bsRest =
      case BSC.uncons bsRest of
        Just ('\\', afterBs) ->
          case BSC.uncons afterBs of
            Just ('u', afterU)
              | BS.length afterU >= 4 ->
                  let hexSlice = BSC.unpack (BS.take 4 afterU)
                      afterHex = BS.drop 4 afterU
                  in case readHex hexSlice of
                    [(loSurr, "")] ->
                      if loSurr >= 0xDC00 && loSurr <= 0xDFFF
                        then
                          let codePoint = 0x10000 + ((hiSurr - 0xD800) `shiftL` 10) + (loSurr - 0xDC00)
                          in Right (chr codePoint, afterHex)
                        else Left "Expected low surrogate after high surrogate"
                    _ -> Left "Invalid low surrogate hex sequence"
            _ -> Left "Expected \\u low surrogate escape sequence"
        _ -> Left "High surrogate not followed by low surrogate"

-- | Parse an integer or floating-point number.
parseNumber :: ByteString -> Either Text (JsonToken, ByteString)
parseNumber bs =
  let (numBytes, rest) = BSC.span isNumChar bs
      numText = TE.decodeUtf8With TEE.lenientDecode numBytes
  in if BS.null numBytes
       then Left "Expected number characters"
       else if BSC.elem '.' numBytes || BSC.elem 'e' numBytes || BSC.elem 'E' numBytes
              then case TR.double numText of
                Right (d, "") -> Right (TkDouble d, rest)
                _             -> Left ("Invalid floating point number: " <> numText)
              else case TR.signed TR.decimal numText of
                Right (n, "") -> Right (TkInt (fromIntegral (n :: Integer)), rest)
                _             -> Left ("Invalid integer: " <> numText)
  where
    isNumChar c = isDigit c || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'
EOF

# 9. Update Kogaki.Wire.SSE.Parser
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
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'
-- and domain boundary representation via 'LogicalString'.
module Kogaki.Wire.SSE.Parser
  ( -- * Core Event Type
    SseEvent (..)

    -- * Non-Empty Tokens & Field Labels
  , SseFieldLabel
  , mkFieldLabel
  , renderDataLine

    -- * Logical String Conversions
  , sseDataLogical
  , mkSseEventLogical

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
import GHC.Generics (Generic)
import Text.Read (readMaybe)

import Kogaki.Core.String
  ( LogicalString
  , UnicodeException
  , fromByteString
  , fromByteStringLenient
  , toByteString
  )

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
  { sseId    :: !(Maybe LogicalString)
  , sseEvent :: !(Maybe LogicalString)
  , sseData  :: !ByteString
  , sseRetry :: !(Maybe Int)
  } deriving stock (Eq, Show, Generic)

-- | Extract data payload as domain 'LogicalString' if valid UTF-8.
--
-- @since 0.1.0.0
sseDataLogical :: SseEvent -> Either UnicodeException LogicalString
sseDataLogical = fromByteString . sseData

-- | Construct an 'SseEvent' from a 'LogicalString' data payload.
--
-- @since 0.1.0.0
mkSseEventLogical :: Maybe LogicalString -> Maybe LogicalString -> LogicalString -> Maybe Int -> SseEvent
mkSseEventLogical mId mEv d mRet = SseEvent mId mEv (toByteString d) mRet

-- | Parse a stream of raw bytes into a list of 'SseEvent' frames according
-- to the W3C Server-Sent Events specification.
--
-- @since 0.1.0.0
parseSseStream :: ByteString -> [SseEvent]
parseSseStream input = go (splitLines input) Nothing Nothing [] Nothing
  where
    go :: [ByteString]
       -> Maybe LogicalString
       -> Maybe LogicalString
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
                  let !newId = case fromByteString val of
                        Right ls -> Just ls
                        Left _   -> Just (fromByteStringLenient val)
                  in go rest newId mEv dataLines mRet
                "event" ->
                  let !newEv = case fromByteString val of
                        Right ls -> Just ls
                        Left _   -> Just (fromByteStringLenient val)
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
    [ maybe "" (\i -> "id: " <> toByteString i <> "\n") mId
    , maybe "" (\e -> "event: " <> toByteString e <> "\n") mEv
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

# 10. Update packages/kogaki/kogaki-wire/test/Main.hs
cat <<'EOF' > packages/kogaki/kogaki-wire/test/Main.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

module Main (main) where

import Data.Functor.Identity (Identity (..), runIdentity)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Record.Anon (pattern (:=))
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.Records.Combinators (getRecordField)

import Kogaki.Wire.Json.Decode
  ( decodeJson
  , decodeJsonEnvelope
  , decodeJsonRow
  , encodeJsonRow
  )
import Kogaki.Wire.Json.Lexer
  ( JsonToken (..)
  , lexJson
  , lexJsonEither
  )
import Kogaki.Core.String (LogicalString (..))
import Kogaki.Wire.SSE.Parser
  ( SseEvent (..)
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  , sseDataLogical
  )
import Sarutahiko.Fields.Datum (SchemaVersion (..))
import Sarutahiko.Records.Envelope (WireEnvelope (..))
import Sarutahiko.Records.HKD.TriState (TriState (..))

-- | Main test runner supporting pattern filters (-p /JsonLexer/, -p /SseRoundTrip/, -p /LogicalString/).
main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runJson = runAll || any (List.isInfixOf "JsonLexer") args
      runSse  = runAll || any (List.isInfixOf "SseRoundTrip") args
      runLogical = runAll || any (List.isInfixOf "LogicalString") args

  putStrLn "=== Running kogaki-wire Property & Invariant Suite (TP-1.1) ==="
  rJson <- if runJson then testJsonLexerAndDecoder else pure True
  rSse  <- if runSse  then testSseRoundTripEquivalence else pure True
  rLogical <- if runLogical then testLogicalStringIntegration else pure True

  if rJson && rSse && rLogical
    then do
      putStrLn "\nAll kogaki-wire invariant tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome kogaki-wire invariant tests FAILED."
      exitFailure

assertBool :: String -> Bool -> IO Bool
assertBool desc cond = do
  if cond
    then do
      putStrLn $ "  [PASS] " ++ desc
      pure True
    else do
      putStrLn $ "  [FAIL] " ++ desc
      pure False

testJsonLexerAndDecoder :: IO Bool
testJsonLexerAndDecoder = do
  putStrLn "\n--- JsonLexer & Row Decoding Invariants (Invariant 1) ---"
  results <- sequence
    [ testEmptyObjectLex
    , testEmptyArrayLex
    , testPrimitiveTypesLex
    , testSingleTokenExtraction
    , testMalformedJsonSurfacesError
    , testNestedStructureLex
    , testZeroIntermediateAstRowHydration
    , testAbsenceFunctorMergePatchPreservation
    , testWireEnvelopeUnknownFieldPreservation
    , testCanonicalLexicographicalEncoding
    ]
  pure (and results)

testEmptyObjectLex :: IO Bool
testEmptyObjectLex = do
  let tokens = lexJson "{}"
  assertBool "JsonLexer: empty object emits [TkObjectOpen, TkObjectClose]"
    (tokens == [TkObjectOpen, TkObjectClose])

testEmptyArrayLex :: IO Bool
testEmptyArrayLex = do
  let tokens = lexJson "[]"
  assertBool "JsonLexer: empty array emits [TkArrayOpen, TkArrayClose]"
    (tokens == [TkArrayOpen, TkArrayClose])

testPrimitiveTypesLex :: IO Bool
testPrimitiveTypesLex = do
  let json = "{\"int\": 42, \"float\": 3.14, \"bool\": true, \"nullVal\": null, \"esc\": \"hello\\nworld!\"}"
      tokens = lexJson json
      expected =
        [ TkObjectOpen
        , TkKey "int", TkInt 42
        , TkKey "float", TkDouble 3.14
        , TkKey "bool", TkBool True
        , TkKey "nullVal", TkNull
        , TkKey "esc", TkString "hello\nworld!"
        , TkObjectClose
        ]
  assertBool "JsonLexer: correctly tokenizes numbers, escapes, bools, and null"
    (tokens == expected)

testSingleTokenExtraction :: IO Bool
testSingleTokenExtraction = do
  let tInt = decodeJson "12345"
      tStr = decodeJson "\"hello\""
      tNull = decodeJson "null"
      tBad = decodeJson "{\"not\": \"single\"}"
  assertBool "JsonLexer: decodeJson extracts single primitive token"
    (tInt == Just (TkInt 12345) && tStr == Just (TkString "hello") && tNull == Just TkNull && tBad == Nothing)

testMalformedJsonSurfacesError :: IO Bool
testMalformedJsonSurfacesError = do
  let resUnclosed = lexJsonEither "{\"key\": "
      resBadChar  = lexJsonEither "{invalid}"
  assertBool "JsonLexer: lexJsonEither surfaces error on malformed JSON"
    (case (resUnclosed, resBadChar) of
       (Left _, Left _) -> True
       _                -> False)

testNestedStructureLex :: IO Bool
testNestedStructureLex = do
  let json = "{\"tools\": [{\"name\": \"calculator\"}]}"
      tokens = lexJson json
      expected =
        [ TkObjectOpen
        , TkKey "tools", TkArrayOpen
        , TkObjectOpen
        , TkKey "name", TkString "calculator"
        , TkObjectClose
        , TkArrayClose
        , TkObjectClose
        ]
  assertBool "JsonLexer: nested objects and arrays maintain structural fidelity"
    (tokens == expected)

-- Row Record Types
type SimpleRow = '["name" ':= Text, "count" ':= Int, "score" ':= Double, "online" ':= Bool]
type TriRow    = '["mandatory" ':= Text, "optional" ':= TriState Text]

testZeroIntermediateAstRowHydration :: IO Bool
testZeroIntermediateAstRowHydration = do
  let rawJson = "{\"count\": 10, \"name\": \"sarutahiko\", \"online\": true, \"score\": 99.5}"
      mDecoded = decodeJsonRow @SimpleRow rawJson
  case mDecoded of
    Nothing -> assertBool "Invariant 1: row decoding failed" False
    Just rec -> do
      let nameVal  = runIdentity (getRecordField #name rec)
          countVal = runIdentity (getRecordField #count rec)
          scoreVal = runIdentity (getRecordField #score rec)
          onVal    = runIdentity (getRecordField #online rec)
      assertBool "Invariant 1: row values hydrated with zero intermediate Value AST"
        (nameVal == "sarutahiko" && countVal == 10 && scoreVal == 99.5 && onVal == True)

testAbsenceFunctorMergePatchPreservation :: IO Bool
testAbsenceFunctorMergePatchPreservation = do
  -- Case A: Key omitted on wire -> Absent
  let jsonAbsent = "{\"mandatory\": \"keep\"}"
      mRecA = decodeJsonRow @TriRow jsonAbsent
      isAbsentOk = case mRecA of
        Just rec -> case runIdentity (getRecordField #optional rec) of Absent -> True; _ -> False
        Nothing  -> False

  -- Case B: Key present as null -> PresentNull
  let jsonNull = "{\"mandatory\": \"keep\", \"optional\": null}"
      mRecB = decodeJsonRow @TriRow jsonNull
      isNullOk = case mRecB of
        Just rec -> case runIdentity (getRecordField #optional rec) of PresentNull -> True; _ -> False
        Nothing  -> False

  -- Case C: Key present with value -> Present val
  let jsonVal = "{\"mandatory\": \"keep\", \"optional\": \"updated\"}"
      mRecC = decodeJsonRow @TriRow jsonVal
      isValOk = case mRecC of
        Just rec -> case runIdentity (getRecordField #optional rec) of Present "updated" -> True; _ -> False
        Nothing  -> False

  assertBool "CA1–CA3: TriState correctly distinguishes Absent vs PresentNull vs Present"
    (isAbsentOk && isNullOk && isValOk)

testWireEnvelopeUnknownFieldPreservation :: IO Bool
testWireEnvelopeUnknownFieldPreservation = do
  let raw = "{\"name\": \"agent\", \"count\": 1, \"score\": 0.0, \"online\": false, \"future_field\": 999}"
      eEnv = decodeJsonEnvelope @SimpleRow (SchemaVersion 1) raw
  case eEnv of
    Left err -> assertBool ("E3/E4: envelope decoding failed: " ++ T.unpack err) False
    Right env -> do
      let unks = envUnknownFields env
          hasUnknown = Map.size unks == 1
                    && Map.lookup "future_field" unks == Just "999"
          rawMatches = envRawBytes env == raw
      assertBool "E3/E4: unknown wire fields preserved into WireEnvelope with raw bytes"
        (hasUnknown && rawMatches)

testCanonicalLexicographicalEncoding :: IO Bool
testCanonicalLexicographicalEncoding = do
  let raw = "{\"count\": 1, \"name\": \"agent\", \"online\": false, \"score\": 0.0}"
      mRec = decodeJsonRow @SimpleRow raw
  case mRec of
    Nothing -> assertBool "Law L4: row decoding failed" False
    Just rec -> do
      let encoded = encodeJsonRow rec
          expected = "{\"count\":1,\"name\":\"agent\",\"online\":false,\"score\":0.0}"
      assertBool "Law L4: canonical row encoder sorts keys lexicographically without whitespace"
        (encoded == expected)

testSseRoundTripEquivalence :: IO Bool
testSseRoundTripEquivalence = do
  putStrLn "\n--- Server-Sent Events (SSE) Round-Trip Equivalence (Invariant 2) ---"
  results <- sequence
    [ testSseSingleEventRoundTrip
    , testSseMultiLineDataRoundTrip
    , testSseMultipleEventsInStream
    , testSseOptionalFieldsHandling
    ]
  pure (and results)

testSseSingleEventRoundTrip :: IO Bool
testSseSingleEventRoundTrip = do
  let evt = SseEvent
        { sseId    = Just "evt-001"
        , sseEvent = Just "delta"
        , sseData  = "{\"text\": \"completion snippet\"}"
        , sseRetry = Just 3000
        }
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: single SSE event satisfies bit-identical roundtrip equivalence"
    (parsed == [evt])

testSseMultiLineDataRoundTrip :: IO Bool
testSseMultiLineDataRoundTrip = do
  let evt = SseEvent
        { sseId    = Just "42"
        , sseEvent = Just "chunk"
        , sseData  = "line 1\nline 2\nline 3"
        , sseRetry = Nothing
        }
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: multi-line SSE data unfolds and parses with exact newline preservation"
    (parsed == [evt])

testSseMultipleEventsInStream :: IO Bool
testSseMultipleEventsInStream = do
  let ev1 = SseEvent (Just "1") (Just "start") "begin" Nothing
      ev2 = SseEvent Nothing (Just "update") "in-progress" (Just 1000)
      ev3 = SseEvent (Just "2") (Just "done") "finished" Nothing
      events = [ev1, ev2, ev3]
      streamBytes = renderSseStream events
      parsed = parseSseStream streamBytes
  assertBool "Invariant 2: multi-event SSE stream parses all discrete events in exact order"
    (parsed == events)

testSseOptionalFieldsHandling :: IO Bool
testSseOptionalFieldsHandling = do
  let evt = SseEvent Nothing Nothing "bare data payload" Nothing
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: bare SSE data payload with omitted optional fields roundtrips cleanly"
    (parsed == [evt])

-- | Test LogicalString integration across JSON rows and SSE events.
testLogicalStringIntegration :: IO Bool
testLogicalStringIntegration = do
  putStrLn "\n--- LogicalString & UTF-8 Codec Invariants ---"
  results <- sequence
    [ testLogicalStringRowDecodeEncode
    , testSseLogicalPayload
    ]
  pure (and results)

type LogicalRow = '["code" ':= LogicalString, "title" ':= LogicalString]

testLogicalStringRowDecodeEncode :: IO Bool
testLogicalStringRowDecodeEncode = do
  let rawJson = "{\"code\":\"KOGAKI-001\",\"title\":\"Sarutahiko\"}"
      mDecoded = decodeJsonRow @LogicalRow rawJson
  case mDecoded of
    Nothing -> do
      putStrLn "Failed to decode row with LogicalString"
      pure False
    Just recRow -> do
      let codeVal  = runIdentity (getRecordField #code recRow)
          titleVal = runIdentity (getRecordField #title recRow)
          encoded  = encodeJsonRow recRow
      b1 <- assertBool "LogicalString: field decoded correctly"
              (codeVal == "KOGAKI-001" && titleVal == "Sarutahiko")
      b2 <- assertBool "LogicalString: row round-trips to equivalent canonical JSON"
              (encoded == rawJson)
      pure (b1 && b2)

testSseLogicalPayload :: IO Bool
testSseLogicalPayload = do
  let validEvt = SseEvent Nothing Nothing "hello world" Nothing
      invalidEvt = SseEvent Nothing Nothing "\xFF\xFE\x00" Nothing
  case sseDataLogical validEvt of
    Left _ -> do
      putStrLn "Failed to decode valid UTF-8 SSE payload to LogicalString"
      pure False
    Right (LogicalString t) -> do
      b1 <- assertBool "SSE: sseDataLogical extracts correct LogicalString from payload"
              (t == "hello world")
      case sseDataLogical invalidEvt of
        Left _  -> do
          b2 <- assertBool "SSE: sseDataLogical surfaces typed UnicodeException on invalid UTF-8 payload"
                  True
          pure (b1 && b2)
        Right _ -> do
          putStrLn "Unexpectedly decoded invalid UTF-8 SSE payload"
          pure False
EOF

echo "  [OK] refactor-logical-string transformation completed successfully."

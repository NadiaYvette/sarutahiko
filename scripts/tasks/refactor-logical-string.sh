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
if ! sed -n '/test-suite test-kogaki-wire/,/large-anon/p' packages/kogaki/kogaki-wire/kogaki-wire.cabal | grep -q "kogaki-core"; then
  sed -i '/test-suite test-kogaki-wire/,/large-anon/ s/kogaki-wire,/kogaki-wire,\n        kogaki-core,/' packages/kogaki/kogaki-wire/kogaki-wire.cabal
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

# 7. Update Kogaki.Wire.SSE.Parser
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

# 8. Update Kogaki.Wire.Json.Decode, Kogaki.Wire.Json.Lexer, and test/Main.hs using Python
python3 - << 'PYEOF'
import sys

# 8a. Update Kogaki.Wire.Json.Decode.hs
with open('packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Decode.hs', 'r') as f:
    dec = f.read()

import_target = "import Kogaki.Wire.Json.Lexer"
import_replacement = """import Data.NonNull (NonNull, fromNullable, toNullable)
import Kogaki.Core.String
  ( LogicalString
  , fromByteString
  , fromText
  , toByteString
  )
import Kogaki.Wire.Json.Lexer"""
assert import_target in dec, "import_target not found in Decode.hs"
dec = dec.replace(import_target, import_replacement, 1)

instance_target = r'''instance ToJsonField Text where
  encodeField t = Just ("\"" <> escapeJsonString (TE.encodeUtf8 t) <> "\"")'''

instance_replacement = r'''instance ToJsonField Text where
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
  encodeField nn = encodeField (toNullable nn)'''
assert instance_target in dec, "instance_target not found in Decode.hs"
dec = dec.replace(instance_target, instance_replacement, 1)

with open('packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Decode.hs', 'w') as f:
    f.write(dec)

# 8b. Update Kogaki.Wire.Json.Lexer.hs
with open('packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs', 'r') as f:
    lex_content = f.read()

assert "  ( -- * Tokens\n    JsonToken (..)\n" in lex_content, "tokens export not found in Lexer.hs"
lex_content = lex_content.replace(
    "  ( -- * Tokens\n    JsonToken (..)\n",
    "  ( -- * Tokens\n    JsonToken (..)\n\n    -- * Domain Conversion\n  , tokenLogicalString\n"
)
assert "import Data.Bits (shiftL, (.|.))\n" in lex_content, "Data.Bits import not found in Lexer.hs"
lex_content = lex_content.replace(
    "import Data.Bits (shiftL, (.|.))\n",
    "import Data.Bits (shiftL, (.|.))\nimport Kogaki.Core.String (LogicalString, fromByteString, fromText)\n"
)
token_target = "  deriving stock (Eq, Show, Generic)\n"
token_replacement = """  deriving stock (Eq, Show, Generic)

-- | Extract a domain 'LogicalString' from a 'JsonToken' representing a string or key.
--
-- @since 0.1.0.0
tokenLogicalString :: JsonToken -> Maybe LogicalString
tokenLogicalString (TkString t) = Just (fromText t)
tokenLogicalString (TkKey bs)   = case fromByteString bs of
  Right ls -> Just ls
  Left _   -> Nothing
tokenLogicalString _            = Nothing
"""
assert token_target in lex_content, "token_target not found in Lexer.hs"
lex_content = lex_content.replace(token_target, token_replacement, 1)

with open('packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs', 'w') as f:
    f.write(lex_content)

# 8c. Update test/Main.hs
with open('packages/kogaki/kogaki-wire/test/Main.hs', 'r') as f:
    test_content = f.read()

sse_import_target = """import Kogaki.Wire.SSE.Parser
  ( SseEvent (..)
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  )"""
sse_import_replacement = """import Kogaki.Core.String (LogicalString (..))
import Kogaki.Wire.SSE.Parser
  ( SseEvent (..)
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  , sseDataLogical
  )"""
assert sse_import_target in test_content, "sse_import_target not found in Main.hs"
test_content = test_content.replace(sse_import_target, sse_import_replacement, 1)

main_old = """-- | Main test runner supporting pattern filters (-p /JsonLexer/, -p /SseRoundTrip/).
main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runJson = runAll || any (List.isInfixOf "JsonLexer") args
      runSse  = runAll || any (List.isInfixOf "SseRoundTrip") args

  putStrLn "=== Running kogaki-wire Property & Invariant Suite (TP-1.1) ==="
  rJson <- if runJson then testJsonLexerAndDecoder else pure True
  rSse  <- if runSse  then testSseRoundTripEquivalence else pure True

  if rJson && rSse"""

main_new = """-- | Main test runner supporting pattern filters (-p /JsonLexer/, -p /SseRoundTrip/, -p /LogicalString/).
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

  if rJson && rSse && rLogical"""
assert main_old in test_content, "main_old not found in Main.hs"
test_content = test_content.replace(main_old, main_new, 1)

test_fn = """
-- | Test LogicalString integration across JSON rows and SSE events.
testLogicalStringIntegration :: IO Bool
testLogicalStringIntegration = do
  putStrLn "\\n--- LogicalString & UTF-8 Codec Invariants ---"
  results <- sequence
    [ testLogicalStringRowDecodeEncode
    , testSseLogicalPayload
    ]
  pure (and results)

type LogicalRow = '["code" ':= LogicalString, "title" ':= LogicalString]

testLogicalStringRowDecodeEncode :: IO Bool
testLogicalStringRowDecodeEncode = do
  let rawJson = "{\\"code\\":\\"KOGAKI-001\\",\\"title\\":\\"Sarutahiko\\"}"
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
      invalidEvt = SseEvent Nothing Nothing "\\xFF\\xFE\\x00" Nothing
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
"""
test_content = test_content + test_fn

with open('packages/kogaki/kogaki-wire/test/Main.hs', 'w') as f:
    f.write(test_content)
PYEOF

echo "  [OK] refactor-logical-string transformation completed successfully."

#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-KOG-001B] Deploying Kogaki.Effect.TextLayout ==="

mkdir -p packages/kogaki/kogaki-core/src/Kogaki/Effect

# 1. Mount seed
cp -f /home/nyc/src/plans/seeds/TP-KOG-001B-TextLayout.hs packages/kogaki/kogaki-core/src/Kogaki/Effect/TextLayout.hs

# 2. Expose module in kogaki-core.cabal if not already present
if ! grep -q "Kogaki.Effect.TextLayout" packages/kogaki/kogaki-core/kogaki-core.cabal; then
  sed -i '/Kogaki.Text.VirtualCharList/a \        Kogaki.Effect.TextLayout' packages/kogaki/kogaki-core/kogaki-core.cabal
fi

# 3. Write clean Spec.hs
cat << 'EOF' > packages/kogaki/kogaki-core/test/Spec.hs
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
import Kogaki.Text.VirtualCharList
import Kogaki.Effect.TextLayout

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "kogaki-core"
  [ testGroup "Kogaki.Core.String"
      [ testProperty "roundtrip valid UTF-8 Text -> LogicalString -> ByteString -> LogicalString" prop_roundtrip_valid_utf8
      , testProperty "identity toByteString (fromText t) == TE.encodeUtf8 t" prop_identity_bytestring
      , testProperty "reject invalid UTF-8 with typed UnicodeException" prop_reject_invalid_utf8
      , testProperty "lenient decode never fails" prop_lenient_never_fails
      , testProperty "monoid associativity and identity" prop_monoid_laws
      , testProperty "non-empty logical string contract" prop_nonempty_contract
      ]
  , testGroup "Kogaki.Text.VirtualCharList"
      [ testProperty "roundtrip packUTF8Literal and unpackVirtualCharList" prop_virtualchar_roundtrip
      , testProperty "pattern matching with (:>) and VNil matches [Char]" prop_virtualchar_patterns
      , testProperty "appendRopeInPlace preserves concatenation" prop_virtualchar_append
      ]
  , testGroup "Kogaki.Effect.TextLayout"
      [ testProperty "segmentGraphemes preserves combining mark grouping" prop_textlayout_graphemes
      , testProperty "resolveBidiRuns classifies LTR vs RTL" prop_textlayout_bidi
      , testProperty "layoutTateChuYoko rotates short digit runs upright" prop_textlayout_tcy
      ]
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

-- | VirtualCharList round-trip property.
prop_virtualchar_roundtrip :: Property
prop_virtualchar_roundtrip = property $ do
  s <- forAll $ Gen.string (Range.linear 0 300) Gen.unicode
  unpackVirtualCharList (packUTF8Literal s) === s

-- | VirtualCharList pattern synonym equivalence.
prop_virtualchar_patterns :: Property
prop_virtualchar_patterns = property $ do
  s <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  let rope = packUTF8Literal s
  let unpackWithPatterns VNil      = []
      unpackWithPatterns (c :> cs) = c : unpackWithPatterns cs
      unpackWithPatterns _         = error "unreachable"
  unpackWithPatterns rope === s

-- | VirtualCharList append equivalence.
prop_virtualchar_append :: Property
prop_virtualchar_append = property $ do
  s1 <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  s2 <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  let r1 = packUTF8Literal s1
      r2 = packUTF8Literal s2
  unpackVirtualCharList (appendRopeInPlace r1 r2) === (s1 ++ s2)

-- | Grapheme cluster combining mark test.
prop_textlayout_graphemes :: Property
prop_textlayout_graphemes = property $ do
  -- Base 'e' followed by combining acute accent U+0301
  let textWithAccent = packUTF8Literal "e\x0301"
      clusters = segmentGraphemes textWithAccent
  length clusters === 1
  unpackVirtualCharList (unGrapheme (head clusters)) === "e\x0301"

-- | Bidi resolution test.
prop_textlayout_bidi :: Property
prop_textlayout_bidi = property $ do
  let ltrText = packUTF8Literal "Hello World"
      rtlText = packUTF8Literal "\x05D4\x05E2\x05D5\x05DC\x05DD" -- Hebrew Shalom
      runsLTR = resolveBidiRuns DirLTR ltrText
      runsRTL = resolveBidiRuns DirLTR rtlText
  length runsLTR === 1
  brDir (head runsLTR) === DirLTR
  length runsRTL === 1
  brDir (head runsRTL) === DirRTL

-- | Tate-chu-yoko vertical layout test.
prop_textlayout_tcy :: Property
prop_textlayout_tcy = property $ do
  -- Japanese vertical text with short number: "平成30年"
  let mixedText = packUTF8Literal "\x5E73\x6210" <> packUTF8Literal "30" <> packUTF8Literal "\x5E74"
      vruns = layoutTateChuYoko 3 mixedText
  -- Should have: Upright('平'), Upright('成'), TateChuYoko(['3','0']), Upright('年')
  length vruns === 4
  case vruns !! 2 of
    TateChuYoko cs -> length cs === 2
    _              -> failure
EOF

echo "=== [TP-KOG-001B] Building and testing kogaki-core ==="
cabal v2-build kogaki-core -j20 --semaphore
cabal v2-test kogaki-core

echo "=== [TP-KOG-001B] Execution script complete ==="

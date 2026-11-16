#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-KOG-001A] Deploying Kogaki.Text.VirtualCharList ==="

mkdir -p packages/kogaki/kogaki-core/src/Kogaki/Text

# 1. Mount pre-staged seed
cp -f /home/nyc/src/plans/seeds/TP-KOG-001A-VirtualCharList.hs packages/kogaki/kogaki-core/src/Kogaki/Text/VirtualCharList.hs

# 2. Expose module in kogaki-core.cabal if not already present
if ! grep -q "Kogaki.Text.VirtualCharList" packages/kogaki/kogaki-core/kogaki-core.cabal; then
  sed -i '/exposed-modules:/a \        Kogaki.Text.VirtualCharList' packages/kogaki/kogaki-core/kogaki-core.cabal
fi

# 3. Write clean test/Spec.hs
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
EOF

echo "=== [TP-KOG-001A] Building and testing kogaki-core ==="
cabal v2-build kogaki-core -j20 --semaphore
cabal v2-test kogaki-core

echo "=== [TP-KOG-001A] Execution script complete ==="

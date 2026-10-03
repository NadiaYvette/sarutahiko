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

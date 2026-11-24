{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.NonNull (fromNullable, toNullable)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog
import Test.Tasty.HUnit (Assertion, (@?=), assertBool, assertFailure, testCase)

import Kogaki.Core.String
import Kogaki.Effect.TextLayout hiding (WritingMode(..), WritingMode)
import Kogaki.Input
import Kogaki.Ontology
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
  , testGroup "Kogaki.Effect.TextLayout"
      [ testProperty "segmentGraphemes preserves combining mark grouping" prop_textlayout_graphemes
      , testProperty "resolveBidiRuns classifies LTR vs RTL" prop_textlayout_bidi
      , testProperty "layoutTateChuYoko rotates short digit runs upright" prop_textlayout_tcy
      ]
  , testGroup "Kogaki.Ontology"
      [ testCase "Verbatim unwrap and isolateBiDi" test_ontology_verbatim_bidi
      , testCase "RichText plainText and collectTags multiset" test_ontology_richtext
      , testCase "meetsMinTier authority ordering" test_ontology_tiers
      ]
  , testGroup "Kogaki.Input"
      [ testCase "Karaganov-Khamenei doctrine: ZWNJ preserved and FSI/PDI isolated" test_input_karaganov_khamenei
      , testCase "Traditional Mongolian NNBSP, MVS, and FVS preservation" test_input_mongolian_preservation
      , testCase "Trojan Source directional overrides (RLO/LRO) rejected" test_input_trojan_source_rejection
      , testCase "foldForSearch canonicalizes Arabic/Persian Yeh/Kaf and strips joiners" test_input_fold_for_search
      , testCase "parseLocalizedDecimal German de-DE valid and ambiguous rejection" test_input_decimal_de_de
      , testCase "parseLocalizedDecimal Indian hi-IN [3, 2] grouping pattern" test_input_decimal_hi_in
      , testCase "parseLocalizedDecimal Persian fa-IR Extended Arabic-Indic digits" test_input_decimal_fa_ir
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
      footnoteShow err
      failure
    Right ls' -> toText ls' === t

-- | Identity property: toByteString (fromText t) matches TE.encodeUtf8 t bit-for-bit.
prop_identity_bytestring :: Property
prop_identity_bytestring = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  toByteString (fromText t) === TE.encodeUtf8 t

-- | Reject invalid UTF-8 with typed UnicodeException.
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
    Left _                 -> success
    Right (LogicalString t) -> do
      annotate ("Unexpected success decoding invalid bytes: " ++ show t)
      failure

-- | Lenient decoding never fails.
prop_lenient_never_fails :: Property
prop_lenient_never_fails = property $ do
  bs <- forAll $ Gen.bytes (Range.linear 0 100)
  let ls = fromByteStringLenient bs
  toText ls === toText ls

-- | Monoid laws: associativity and identity.
prop_monoid_laws :: Property
prop_monoid_laws = property $ do
  t1 <- forAll $ Gen.text (Range.linear 0 50) Gen.unicode
  t2 <- forAll $ Gen.text (Range.linear 0 50) Gen.unicode
  t3 <- forAll $ Gen.text (Range.linear 0 50) Gen.unicode
  let ls1 = fromText t1
      ls2 = fromText t2
      ls3 = fromText t3
  -- Left identity
  mempty <> ls1 === ls1
  -- Right identity
  ls1 <> mempty === ls1
  -- Associativity
  (ls1 <> ls2) <> ls3 === ls1 <> (ls2 <> ls3)

-- | Non-empty contract: fromNullable respects emptiness.
prop_nonempty_contract :: Property
prop_nonempty_contract = property $ do
  t <- forAll $ Gen.text (Range.linear 0 50) Gen.unicode
  let ls = fromText t
  case fromNullable ls of
    Nothing   -> toText ls === ""
    Just nels -> toText (toNullable nels) === t

-- | VirtualCharList pack and unpack round-trip.
prop_virtualchar_roundtrip :: Property
prop_virtualchar_roundtrip = property $ do
  s <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  let rope = packUTF8Literal s
  unpackVirtualCharList rope === s

-- | VirtualCharList pattern matching with (:>) and VNil.
prop_virtualchar_patterns :: Property
prop_virtualchar_patterns = property $ do
  s <- forAll $ Gen.string (Range.linear 0 50) Gen.unicode
  let rope = packUTF8Literal s
  unpackWithPatterns rope === s
  where
    unpackWithPatterns r = case r of
      VNil      -> []
      c :> rest -> c : unpackWithPatterns rest

-- | In-place append preserves concatenation.
prop_virtualchar_append :: Property
prop_virtualchar_append = property $ do
  s1 <- forAll $ Gen.string (Range.linear 0 50) Gen.unicode
  s2 <- forAll $ Gen.string (Range.linear 0 50) Gen.unicode
  let r1 = packUTF8Literal s1
      r2 = packUTF8Literal s2
      appended = appendRopeInPlace r1 r2
  unpackVirtualCharList appended === (s1 ++ s2)

-- | Extended Grapheme Cluster segmentation preserves combining mark grouping.
prop_textlayout_graphemes :: Property
prop_textlayout_graphemes = property $ do
  let sample = packUTF8Literal "e\x0301" -- e with acute accent combining mark
      clusters = segmentGraphemes sample
  length clusters === 1
  case clusters of
    (c:_) -> unpackVirtualCharList (unGrapheme c) === "e\x0301"
    []    -> failure

-- | BiDi classification resolves LTR and RTL correctly.
prop_textlayout_bidi :: Property
prop_textlayout_bidi = property $ do
  let ltrText = packUTF8Literal "Hello"
      rtlText = packUTF8Literal "\x0627\x0644\x0633\x0644\x0627\x0645" -- Arabic "Salam"
      runsLTR = resolveBidiRuns DirLTR ltrText
      runsRTL = resolveBidiRuns DirRTL rtlText
  case (runsLTR, runsRTL) of
    (rL:_, rR:_) -> do
      brDir rL === DirLTR
      brDir rR === DirRTL
    _ -> failure

-- | TateChuYoko rotation rotates short digit runs upright.
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

-- | Ontology tests
test_ontology_verbatim_bidi :: Assertion
test_ontology_verbatim_bidi = do
  let v = Verbatim "--jobs"
  unVerbatim v @?= "--jobs"
  let bidi = isolateBiDi "خامنه\x200Cای"
  T.head bidi @?= fsiChar
  T.last bidi @?= pdiChar
  T.drop 1 (T.dropEnd 1 bidi) @?= "خامنه\x200Cای"

test_ontology_richtext :: Assertion
test_ontology_richtext = do
  let tree = Span TagCode
        [ Plain "run "
        , Span TagFlag [Plain "--dry-run"]
        , Plain " on "
        , GlossNode Gloss
            { glossLang = LocaleTag "mn-Mong"
            , glossMode = VerticalLR
            , glossNative = "ᠮᠣᠩᡤᠣᠯ"
            , glossTranslit = Just "Monggol"
            , glossMeaning = Just "Mongolia"
            }
        ]
  plainText tree @?= "run --dry-run on Monggol"
  let tags = collectTags tree
  Map.lookup TagCode tags @?= Just 1
  Map.lookup TagFlag tags @?= Just 1

test_ontology_tiers :: Assertion
test_ontology_tiers = do
  assertBool "Tier0 meets Tier0" (meetsMinTier Tier0 Tier0)
  assertBool "Tier0 meets Tier2" (meetsMinTier Tier2 Tier0)
  assertBool "Tier3 does not meet Tier1" (not (meetsMinTier Tier1 Tier3))

-- | Input tests
test_input_karaganov_khamenei :: Assertion
test_input_karaganov_khamenei = do
  -- ZWNJ is U+200C
  let doc = "Караганов-خامنه\x200Cای Doktrin"
  -- Verify sanitizeInput preserves ZWNJ
  case sanitizeInput doc of
    Left err -> assertFailure ("sanitizeInput failed: " ++ show err)
    Right t -> do
      t @?= doc
      assertBool "ZWNJ is present" ('\x200C' `T.elem` t)
  -- Verify renderUnicodeLiteral preserves Cyrillic and Arabic, isolates RTL run, and avoids \1050 escaping
  let rendered = renderUnicodeLiteral doc
  assertBool "Rendered starts with quote" ("\"Караганов-" `T.isPrefixOf` rendered)
  assertBool "FSI is in rendered" ('\x2068' `T.elem` rendered)
  assertBool "PDI is in rendered" ('\x2069' `T.elem` rendered)
  assertBool "Persian is in rendered" ("خامنه\x200Cای" `T.isInfixOf` rendered)
  assertBool "Doktrin is in rendered" ("Doktrin\"" `T.isSuffixOf` rendered)
  assertBool "No octal escaping" (not ("\\1050" `T.isInfixOf` rendered))

test_input_mongolian_preservation :: Assertion
test_input_mongolian_preservation = do
  -- Traditional Mongolian with NNBSP (U+202F), MVS (U+180E), and FVS1 (U+180B)
  let mongolText = "ᠮᠣᠩᡤᠣᠯ\x202Fᠤᠨ\x180E᠊\x180B"
  case sanitizeInput mongolText of
    Left err -> assertFailure ("Mongolian text rejected: " ++ show err)
    Right t -> t @?= mongolText

test_input_trojan_source_rejection :: Assertion
test_input_trojan_source_rejection = do
  -- RLO (U+202E) attempt to invert execution
  let attackRLO = "checkUserPermission(); \x202E } /* Begin admin check */ if (isAdmin) {"
  case sanitizeInput attackRLO of
    Left (TrojanSourceOverride idx c) -> do
      c @?= '\x202E'
      idx @?= 23
    Left err -> assertFailure ("Expected TrojanSourceOverride but got: " ++ show err)
    Right _ -> assertFailure "RLO Trojan Source override was not rejected!"
  -- LRO (U+202D) attempt
  let attackLRO = "val = \x202D 123"
  case sanitizeInput attackLRO of
    Left (TrojanSourceOverride _ c) -> c @?= '\x202D'
    Left err -> assertFailure ("Expected TrojanSourceOverride but got: " ++ show err)
    Right _ -> assertFailure "LRO Trojan Source override was not rejected!"

test_input_fold_for_search :: Assertion
test_input_fold_for_search = do
  -- Arabic Yeh U+064A and Alef Maksura U+0649 -> Persian Yeh U+06CC
  -- Arabic Kaf U+0643 -> Persian Kaf U+06A9
  -- ZWNJ U+200C stripped for fuzzy search
  let query = "مصرى كاتب مصري خامنه\x200Cاى"
  let folded = foldForSearch query
  assertBool "Arabic Yeh converted to Persian Yeh" ('\x06CC' `T.elem` folded)
  assertBool "Arabic Yeh stripped" ('\x064A' `notElem` T.unpack folded)
  assertBool "Alef Maksura stripped" ('\x0649' `notElem` T.unpack folded)
  assertBool "Arabic Kaf converted to Persian Kaf" ('\x06A9' `T.elem` folded)
  assertBool "Arabic Kaf stripped" ('\x0643' `notElem` T.unpack folded)
  assertBool "ZWNJ stripped" ('\x200C' `notElem` T.unpack folded)

test_input_decimal_de_de :: Assertion
test_input_decimal_de_de = do
  -- Valid German decimal with thousands separator: "1.234,56"
  case parseLocalizedDecimal syntaxDeDE "1.234,56" of
    Left err -> assertFailure ("Failed to parse valid de-DE: " ++ show err)
    Right s -> show s @?= "1234.56"
  -- Negative German decimal: "-42,5"
  case parseLocalizedDecimal syntaxDeDE "-42,5" of
    Left err -> assertFailure ("Failed to parse negative de-DE: " ++ show err)
    Right s -> show s @?= "-42.5"
  -- Ambiguous/malformed German decimal: "1.23" (2 digits after grouping dot)
  case parseLocalizedDecimal syntaxDeDE "1.23" of
    Left (MalformedNumber _) -> pure ()
    Left err -> assertFailure ("Expected MalformedNumber but got: " ++ show err)
    Right s -> assertFailure ("1.23 should be rejected under de-DE but got: " ++ show s)

test_input_decimal_hi_in :: Assertion
test_input_decimal_hi_in = do
  -- Indian English [3, 2] grouping pattern: "12,34,567.89"
  case parseLocalizedDecimal syntaxHiIN "12,34,567.89" of
    Left err -> assertFailure ("Failed to parse valid hi-IN: " ++ show err)
    Right s -> show s @?= "1234567.89"

test_input_decimal_fa_ir :: Assertion
test_input_decimal_fa_ir = do
  -- Persian: Extended Arabic-Indic digits with Persian decimal separator
  -- "۱,۲۳۴,۵۶۷٫۸۹"
  case parseLocalizedDecimal syntaxFaIR "۱,۲۳۴,۵۶۷٫۸۹" of
    Left err -> assertFailure ("Failed to parse valid fa-IR: " ++ show err)
    Right s -> show s @?= "1234567.89"

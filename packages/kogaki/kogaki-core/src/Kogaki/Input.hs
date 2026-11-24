{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: Kogaki.Input
-- Description: Input sanitization, BiDi Trojan Source guards, localized number parsing, and Unicode REPL literal rendering
-- License: EUPL-1.2 OR Apache-2.0
--
-- Provides rigorous input hygiene for multilingual text processing:
-- * 'sanitizeInput' enforces directional boundary hygiene and defends against
--   Trojan Source attacks (CVE-2021-42574) while preserving linguistic zero-width
--   and script formatting controls (ZWNJ, ZWJ, MVS, FVS1..4, NNBSP).
-- * 'foldForSearch' performs fuzzy search normalization (Arabic Yeh/Kaf canonicalization,
--   case-folding, zero-width stripping) without mutating stored text.
-- * 'parseLocalizedDecimal' strictly parses localized numbers according to 'LocaleNumberSyntax',
--   validating digit groups against grouping patterns and supporting multiple native scripts.
-- * 'renderUnicodeLiteral' renders quoted string literals preserving printable Unicode
--   without octal escaping, isolating RTL runs with FSI/PDI.
module Kogaki.Input
  ( -- * Number Syntax Specifications
    LocaleNumberSyntax(..)
  , syntaxISO
  , syntaxDeDE
  , syntaxHiIN
  , syntaxFaIR
    -- * Input Hygiene & Errors
  , InputHygieneError(..)
  , sanitizeInput
    -- * Search Normalization
  , foldForSearch
    -- * Localized Decimal Parsing
  , parseLocalizedDecimal
    -- * Unicode Literal Rendering
  , renderUnicodeLiteral
  ) where

import Control.Monad (when)
import Data.Char (isAscii, isControl, isDigit, ord)
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)

-- | Detailed specification of number formatting rules for a locale.
data LocaleNumberSyntax = LocaleNumberSyntax
  { numDecimalSep      :: !Char
    -- ^ Decimal point separator (e.g. '.' or ',').
  , numGroupSeps       :: ![Char]
    -- ^ Accepted thousands / digit grouping separators.
  , numMinusSigns      :: ![Char]
    -- ^ Accepted minus sign representations (e.g. '-' or '−' U+2212).
  , numDigitZero       :: !Char
    -- ^ Native digit zero character representing the base digit script.
  , numGroupingPattern :: ![Int]
    -- ^ Grouping size pattern from right to left (e.g. [3] for Western, [3, 2] for Indian).
  } deriving stock (Eq, Show)

-- | Standard ISO / Western locale number syntax (e.g. "1 234 567.89").
syntaxISO :: LocaleNumberSyntax
syntaxISO = LocaleNumberSyntax
  { numDecimalSep      = '.'
  , numGroupSeps       = [' ', '\x00A0', '\x202F']
  , numMinusSigns      = ['-', '\x2212']
  , numDigitZero       = '0'
  , numGroupingPattern = [3]
  }

-- | German (de-DE) locale number syntax (e.g. "1.234.567,89").
syntaxDeDE :: LocaleNumberSyntax
syntaxDeDE = LocaleNumberSyntax
  { numDecimalSep      = ','
  , numGroupSeps       = ['.', ' ', '\x00A0', '\x202F']
  , numMinusSigns      = ['-', '\x2212']
  , numDigitZero       = '0'
  , numGroupingPattern = [3]
  }

-- | Indian English / Hindi (hi-IN) locale number syntax (e.g. "12,34,567.89").
syntaxHiIN :: LocaleNumberSyntax
syntaxHiIN = LocaleNumberSyntax
  { numDecimalSep      = '.'
  , numGroupSeps       = [',', ' ', '\x00A0']
  , numMinusSigns      = ['-']
  , numDigitZero       = '0'
  , numGroupingPattern = [3, 2]
  }

-- | Persian (fa-IR) locale number syntax with Extended Arabic-Indic digits (e.g. "۱۲,۳۴,۵۶۷٫۸۹").
syntaxFaIR :: LocaleNumberSyntax
syntaxFaIR = LocaleNumberSyntax
  { numDecimalSep      = '\x066B' -- Arabic decimal separator ٫
  , numGroupSeps       = ['\x066C', ' ', '\x00A0', ','] -- Arabic thousands separator ٬
  , numMinusSigns      = ['-', '\x2212']
  , numDigitZero       = '\x06F0' -- Extended Arabic-Indic digit 0: ۰
  , numGroupingPattern = [3]
  }

-- | Errors raised during text input validation and number parsing.
data InputHygieneError
  = TrojanSourceOverride !Int !Char
    -- ^ Detected disallowed directional override or unmatched isolate at character index.
  | MalformedNumber !Text
    -- ^ String could not be unambiguously parsed as a localized number.
  deriving stock (Eq, Show)

-- | Validates that an incoming text input does not contain Trojan Source overrides
-- (CVE-2021-42574) or unmatched directional isolate controls, while strictly preserving
-- essential linguistic formatting characters:
-- * ZWNJ (@U+200C@ - Zero Width Non-Joiner)
-- * ZWJ (@U+200D@ - Zero Width Joiner)
-- * MVS (@U+180E@ - Mongolian Vowel Separator)
-- * FVS1..4 (@U+180B..U+180D, U+180F@ - Free Variation Selectors)
-- * NNBSP (@U+202F@ - Narrow No-Break Space)
sanitizeInput :: Text -> Either InputHygieneError Text
sanitizeInput input = go 0 0 (T.unpack input)
  where
    go :: Int -> Int -> [Char] -> Either InputHygieneError Text
    go !idx !isolates []
      | isolates /= 0 = Left (TrojanSourceOverride idx '\x2069')
      | otherwise     = Right input
    go !idx !isolates (c:cs)
      | isTrojanOverride c = Left (TrojanSourceOverride idx c)
      | isIsolateOpen c    = go (idx + 1) (isolates + 1) cs
      | c == '\x2069'      =
          if isolates > 0
            then go (idx + 1) (isolates - 1) cs
            else Left (TrojanSourceOverride idx c)
      | otherwise          = go (idx + 1) isolates cs

    -- Trojan Source (CVE-2021-42574) directional overrides:
    -- U+202A (LRE), U+202B (RLE), U+202C (PDF), U+202D (LRO), U+202E (RLO).
    isTrojanOverride c =
      let o = ord c
      in (o >= 0x202A && o <= 0x202E)

    -- Directional isolate openers: U+2066 (LRI), U+2067 (RLI), U+2068 (FSI).
    isIsolateOpen c =
      let o = ord c
      in o >= 0x2066 && o <= 0x2068

-- | Folds text for fuzzy search:
-- * Case-folding via 'T.toCaseFold'.
-- * Maps Arabic Yeh (@U+064A@) -> Persian Yeh (@U+06CC@).
-- * Maps Arabic Kaf (@U+0643@) -> Persian Kaf (@U+06A9@).
-- * Strips non-spacing joiners (ZWNJ @U+200C@, ZWJ @U+200D@, MVS, FVS).
foldForSearch :: Text -> Text
foldForSearch = T.pack . foldr normalizeChar [] . T.unpack . T.toCaseFold
  where
    normalizeChar c acc
      -- Arabic Yeh (U+064A) and Alef Maksura (U+0649) -> Persian Yeh (U+06CC)
      | c == '\x064A' || c == '\x0649' = '\x06CC' : acc
      -- Arabic Kaf (U+0643) -> Persian Kaf (U+06A9)
      | c == '\x0643' = '\x06A9' : acc
      -- Strip zero-width controls for fuzzy lookup only
      | isJoinerOrVariation c = acc
      | otherwise = c : acc

    isJoinerOrVariation c =
      let o = ord c
      in o == 0x200C || o == 0x200D || o == 0x180E || (o >= 0x180B && o <= 0x180D) || o == 0x180F

-- | Parses a localized decimal number into a 'Scientific' value according to the given
-- 'LocaleNumberSyntax'. Validates grouping separator positions against 'numGroupingPattern'.
parseLocalizedDecimal :: LocaleNumberSyntax -> Text -> Either InputHygieneError Scientific
parseLocalizedDecimal syntax rawText = do
  let t = T.strip rawText
  if T.null t
    then Left (MalformedNumber rawText)
    else do
      -- Check sign
      let (isNeg, textNoSign) = case T.uncons t of
            Just (c, rest)
              | c `elem` numMinusSigns syntax -> (True, rest)
            _ -> (False, t)
      if T.null textNoSign
        then Left (MalformedNumber rawText)
        else parseBody isNeg textNoSign
  where
    decSep = numDecimalSep syntax
    groupSeps = numGroupSeps syntax
    groupPat = numGroupingPattern syntax

    parseBody isNeg txt = do
      let parts = T.split (== decSep) txt
      case parts of
        [intStr] -> parseParts isNeg intStr Nothing
        [intStr, fracStr] -> parseParts isNeg intStr (Just fracStr)
        _ -> Left (MalformedNumber rawText)

    parseParts isNeg intStr mFracStr = do
      intVal <- parseIntegerPart intStr
      case mFracStr of
        Nothing ->
          let c = if isNeg then -intVal else intVal
          in Right (scientific c 0)
        Just fracStr -> do
          (fracVal, fracDigits) <- parseFractionalPart fracStr
          let intShifted = intVal * (10 ^ fracDigits)
              totalVal = intShifted + fracVal
              c = if isNeg then -totalVal else totalVal
          Right (scientific c (-fracDigits))

    parseIntegerPart intStr = do
      if T.null intStr
        then Left (MalformedNumber rawText)
        else do
          -- Find which grouping separator is used, if any
          let foundGroupSeps = filter (`elem` groupSeps) (T.unpack intStr)
          case foundGroupSeps of
            [] -> do
              -- Pure digits without grouping
              digits <- mapM charToVal (T.unpack intStr)
              pure (digitsToInteger digits)
            (firstSep:_) -> do
              -- Grouping is present: check grouping consistency
              let chunks = T.split (== firstSep) intStr
              validateGroupingChunks chunks
              let allDigits = T.filter (/= firstSep) intStr
              digits <- mapM charToVal (T.unpack allDigits)
              pure (digitsToInteger digits)

    validateGroupingChunks [] = Left (MalformedNumber rawText)
    validateGroupingChunks [_] = Left (MalformedNumber rawText)
    validateGroupingChunks (firstChunk : restChunks) = do
      when (T.null firstChunk || any T.null restChunks) $
        Left (MalformedNumber rawText)
      -- In reverse order (from lowest digits to highest)
      let revChunks = reverse (firstChunk : restChunks)
          expectedSizes = cyclePattern groupPat
      checkChunkSizes revChunks expectedSizes

    checkChunkSizes [] _ = pure ()
    checkChunkSizes [lastHighest] (expectedSize : _) = do
      -- The leftmost chunk can have 1..expectedSize digits
      let l = T.length lastHighest
      if l >= 1 && l <= expectedSize
        then pure ()
        else Left (MalformedNumber rawText)
    checkChunkSizes (c : cs) (expectedSize : es) = do
      if T.length c == expectedSize
        then checkChunkSizes cs es
        else Left (MalformedNumber rawText)
    checkChunkSizes _ [] = Left (MalformedNumber rawText)

    cyclePattern [] = [3]
    cyclePattern [x] = repeat x
    cyclePattern (x:xs) = x : cyclePattern xs

    parseFractionalPart fracStr = do
      if T.null fracStr
        then Left (MalformedNumber rawText)
        else do
          -- Fractional part cannot have thousands separators
          digits <- mapM charToVal (T.unpack fracStr)
          pure (digitsToInteger digits, length digits)

    charToVal c
      | isDigit c = Right (toInteger (ord c - ord '0'))
      | c >= '\x0660' && c <= '\x0669' = Right (toInteger (ord c - 0x0660)) -- Arabic-Indic
      | c >= '\x06F0' && c <= '\x06F9' = Right (toInteger (ord c - 0x06F0)) -- Extended Arabic-Indic
      | c >= '\x0966' && c <= '\x096F' = Right (toInteger (ord c - 0x0966)) -- Devanagari
      | c >= '\x1810' && c <= '\x1819' = Right (toInteger (ord c - 0x1810)) -- Mongolian
      | otherwise = Left (MalformedNumber rawText)

    digitsToInteger = foldl' (\acc d -> acc * 10 + d) 0

-- | Helper to check if a character belongs to a right-to-left script.
isRtlChar :: Char -> Bool
isRtlChar c =
  let o = ord c
  in (o >= 0x0590 && o <= 0x08FF)
     || (o >= 0xFB1D && o <= 0xFDFF)
     || (o >= 0xFE70 && o <= 0xFEFC)

-- | Renders a string literal preserving printable Unicode characters (avoiding standard
-- Haskell @Show@ octal/decimal escaping like @\1050@), escaping ASCII controls as
-- standard escape codes or @\xXXXX@, and wrapping RTL runs with Unicode FSI (@U+2068@)
-- and PDI (@U+2069@) isolates.
renderUnicodeLiteral :: Text -> Text
renderUnicodeLiteral input =
  T.cons '"' (T.snoc (processRuns (T.unpack input)) '"')
  where
    processRuns [] = T.empty
    processRuns chars =
      let segments = segmentByDirection chars
      in T.concat (map renderSegment segments)

    segmentByDirection [] = []
    segmentByDirection (c:cs)
      | isRtlChar c =
          let (rtlRun, rest) = spanRtl (c:cs)
          in (True, rtlRun) : segmentByDirection rest
      | otherwise =
          let (ltrRun, rest) = spanLtr (c:cs)
          in (False, ltrRun) : segmentByDirection rest

    isRtlNeutral c =
      c == '\x200C' || c == '\x200D' -- ZWNJ/ZWJ can connect within RTL

    spanRtl [] = ([], [])
    spanRtl (c:cs)
      | isRtlChar c || isRtlNeutral c =
          let (r, rest) = spanRtl cs in (c:r, rest)
      | otherwise = ([], c:cs)

    spanLtr [] = ([], [])
    spanLtr (c:cs)
      | not (isRtlChar c) =
          let (r, rest) = spanLtr cs in (c:r, rest)
      | otherwise = ([], c:cs)

    renderSegment (True, cs) =
      -- RTL run: wrap with FSI (U+2068) and PDI (U+2069)
      T.cons '\x2068' (T.snoc (T.concatMap escapeChar (T.pack cs)) '\x2069')
    renderSegment (False, cs) =
      T.concatMap escapeChar (T.pack cs)

    escapeChar c
      | c == '"'  = "\\\""
      | c == '\\' = "\\\\"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | c == '\t' = "\\t"
      | isControl c && isAscii c =
          let h = showHex (ord c) ""
              padded = replicate (4 - length h) '0' ++ h
          in "\\x" <> T.pack padded
      | ord c >= 0x202A && ord c <= 0x202E =
          let h = showHex (ord c) ""
              padded = replicate (4 - length h) '0' ++ h
          in "\\x" <> T.pack padded
      | otherwise = T.singleton c

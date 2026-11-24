{-# LANGUAGE OverloadedStrings #-}

-- | Module: Kogaki.QA
-- Description: Structural catalog linting, NoMT provenance checks, and escape detector
--
-- Validates Project Fluent (.ftl) translation catalogs against reference schemas,
-- enforcing CLDR plural completeness, rejecting raw terminal escapes (ANSI/roff),
-- and barring machine translation on endangered/revitalizing language catalogs.
module Kogaki.QA
  ( QAViolation (..)
  , validateCatalog
  , detectRawEscapes
  , checkNoMT
  ) where

import Data.Char (isAsciiUpper, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Fluent.Polytropos.Schema
  ( CatalogDiff (..)
  , CatalogSchema (..)
  , diffCatalogSchemas
  )
import Kogaki.Locales.Plurals (PluralCategory)
import Kogaki.Ontology
  ( LocalePolicy (..)
  , LocaleTag (..)
  , Provenance (..)
  )

-- | Violations flagged by the kogaki-qa validator.
data QAViolation
  = DisallowedMT !LocaleTag !Text
    -- ^ Endangered language catalog has MachineTranslated provenance when policy forbids MT.
  | RawAnsiEscape !Int !Text
    -- ^ Raw ANSI escape sequence (\\ESC[) found at line number.
  | RawRoffMacro !Int !Text
    -- ^ Raw roff macro (.TH, .SH, etc.) found at line number.
  | IncompletePluralCategories !LocaleTag ![PluralCategory]
    -- ^ Target catalog lacks mandatory CLDR plural forms.
  | SchemaIncompatibility !CatalogDiff
    -- ^ Structural diff against reference catalog shows schema regression.
  deriving stock (Eq, Show)

-- | Checks if provenance violates policy (NoMT on endangered languages).
checkNoMT :: LocalePolicy -> Provenance -> Maybe QAViolation
checkNoMT pol prov =
  case (lpAllowMachineTranslation pol, prov) of
    (False, MachineTranslated engine) ->
      Just (DisallowedMT (lpTag pol) engine)
    _ -> Nothing

-- | Detects raw ANSI escape codes and roff macro lines in raw .ftl file content.
detectRawEscapes :: Text -> [QAViolation]
detectRawEscapes content =
  let linesWithNum = zip [1 :: Int ..] (T.lines content)
  in concatMap checkLine linesWithNum
  where
    checkLine (lineNo, line) =
      let stripped = T.dropWhile isSpace line
          ansiHit = if "\ESC[" `T.isInfixOf` line || "\x1b[" `T.isInfixOf` line
                      then [RawAnsiEscape lineNo line]
                      else []
          roffHit = if "." `T.isPrefixOf` stripped && T.length stripped > 1
                       && not ("." `T.isInfixOf` T.takeWhile (/= ' ') (T.drop 1 stripped))
                       && T.all isAsciiUpper (T.takeWhile (/= ' ') (T.drop 1 stripped))
                       && not (T.null (T.takeWhile (/= ' ') (T.drop 1 stripped)))
                      then [RawRoffMacro lineNo line]
                      else []
      in ansiHit ++ roffHit

-- | Full validation gate run by kogaki-qa.
validateCatalog
  :: LocalePolicy
  -> Provenance
  -> CatalogSchema
  -> CatalogSchema
  -> Text
  -> [QAViolation]
validateCatalog policy prov refSchema targetSchema rawContent =
  let nomtViolations   = maybe [] pure (checkNoMT policy prov)
      escapeViolations = detectRawEscapes rawContent
      diff = diffCatalogSchemas refSchema targetSchema
      diffViolations =
        if cdMissingMessages diff == mempty && cdParamMismatches diff == mempty
          then []
          else [SchemaIncompatibility diff]
  in nomtViolations ++ escapeViolations ++ diffViolations

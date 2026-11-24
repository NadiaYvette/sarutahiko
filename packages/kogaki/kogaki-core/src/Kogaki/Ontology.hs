{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Module: Kogaki.Ontology
-- Description: Seven-stratum type-safe ontology for multilingual i18n, l10n, g11n, and a11y
-- License: EUPL-1.2 OR Apache-2.0
--
-- Distinguishes invariant syntax ('Verbatim'), display-width units ('ColWidth',
-- 'ByteLen', 'GraphemeCount'), 2D script orientation ('WritingMode'), embedded
-- multilingual citations ('Gloss'), semantic inline markup ('RichText'), and
-- translation provenance tiers ('Tier').
module Kogaki.Ontology
  ( -- * Stratum 0: Invariant Syntax & BiDi Isolation
    Verbatim(..)
  , fsiChar
  , pdiChar
  , isolateBiDi
    -- * Stratum 5: Distinct Length Units & 2D Writing Modes
  , ByteLen(..)
  , GraphemeCount(..)
  , ColWidth(..)
  , WritingMode(..)
  , LocaleTag(..)
  , Gloss(..)
  , AccessibleAlt(..)
    -- * Stratum 4: Semantic Inline Markup
  , SemanticTag(..)
  , RichText(..)
  , plainText
  , collectTags
    -- * Stratum 6: Reliability Tiers & Provenance
  , Tier(..)
  , Provenance(..)
  , LocalePolicy(..)
  , meetsMinTier
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | Stratum 0: Invariant technical token (CLI flag, path, code identifier, error code).
--
-- Must never be passed through translation, autocorrect, or locale case-folding.
newtype Verbatim = Verbatim { unVerbatim :: Text }
  deriving stock (Eq, Ord, Show, Read)

-- | Unicode First Strong Isolate (U+2068).
fsiChar :: Char
fsiChar = '\x2068'

-- | Unicode Pop Directional Isolate (U+2069).
pdiChar :: Char
pdiChar = '\x2069'

-- | Wraps an interpolated span in Unicode FSI/PDI directional isolates so
-- mixed LTR/RTL tokens (e.g., flags inside Arabic/Persian prose) never scramble
-- surrounding punctuation.
isolateBiDi :: Text -> Text
isolateBiDi t = T.cons fsiChar (T.snoc t pdiChar)

-- | UTF-8 encoded byte length (wire and buffer sizing only).
newtype ByteLen = ByteLen { unByteLen :: Int }
  deriving stock (Eq, Ord, Show, Read)

-- | Count of UAX #29 Extended Grapheme Clusters (human-perceived characters).
newtype GraphemeCount = GraphemeCount { unGraphemeCount :: Int }
  deriving stock (Eq, Ord, Show, Read)

-- | Monospace terminal display column width (UAX #11 + UCSUR metrics).
newtype ColWidth = ColWidth { unColWidth :: Int }
  deriving stock (Eq, Ord, Show, Read)

-- | Two-dimensional script writing orientation.
data WritingMode
  = HorizontalLTR
    -- ^ Latin, Cyrillic, Greek, Devanagari, horizontal CJK.
  | HorizontalRTL
    -- ^ Arabic, Persian, Urdu, Hebrew, Syriac, Thaana, N'Ko.
  | VerticalRL
    -- ^ Traditional vertical Chinese/Japanese columns progressing right-to-left.
  | VerticalLR
    -- ^ Traditional Mongolian (mn-Mong) columns progressing left-to-right.
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | Normalized BCP 47 language tag (e.g. @"de-DE"@, @"mn-Mong"@, @"tok-x-sitelen-pona"@).
newtype LocaleTag = LocaleTag { unLocaleTag :: Text }
  deriving stock (Eq, Ord, Show, Read)

-- | Linear text alternative for non-linear, graphical (2D SVG), vertical, or PUA scripts
-- ensuring screen-reader and plain-TTY accessibility.
newtype AccessibleAlt = AccessibleAlt { unAccessibleAlt :: Text }
  deriving stock (Eq, Ord, Show, Read)

-- | Stratum 5: A self-contained multilingual citation or gloss node.
data Gloss = Gloss
  { glossLang     :: !LocaleTag
    -- ^ BCP 47 tag identifying the quoted language and script.
  , glossMode     :: !WritingMode
    -- ^ Native 2D writing mode for HTML/PDF rendering.
  , glossNative   :: !Text
    -- ^ Native orthography (preserving ZWNJ, NNBSP, MVS, FVS1..4).
  , glossTranslit :: !(Maybe Text)
    -- ^ Academic transliteration fallback for plain TTY / mdoc(7) / a11y.
  , glossMeaning  :: !(Maybe Text)
    -- ^ Optional inline or tooltip translation.
  } deriving stock (Eq, Ord, Show)

-- | Closed baseline semantic tag vocabulary for Stratum 4 inline markup.
--
-- Rendered without coupling .ftl catalogs to ANSI escapes, mdoc macros, or HTML.
data SemanticTag
  = TagFlag
    -- ^ CLI option or flag (e.g. @--jobs@).
  | TagArg
    -- ^ CLI metavariable / argument placeholder (e.g. @FILE@).
  | TagCode
    -- ^ Inline code, operator, or symbol.
  | TagEmph
    -- ^ Semantic emphasis.
  | TagLink !Text
    -- ^ Named hyperlink / cross-reference identifier.
  | TagLang !LocaleTag !WritingMode
    -- ^ Embedded foreign-language run (emits @lang@ + BiDi isolation).
  deriving stock (Eq, Ord, Show)

-- | Stratum 4: Structured inline rich text parameterized over tag type.
data RichText tag
  = Plain !Text
    -- ^ Unformatted prose run.
  | Span !tag ![RichText tag]
    -- ^ Semantically tagged nested inline span.
  | GlossNode !Gloss
    -- ^ Multilingual citation carrying native + transliterated + meaning fields.
  deriving stock (Eq, Show, Functor)

-- | Strips all markup to plain linear text (using transliteration fallback for vertical scripts).
plainText :: RichText tag -> Text
plainText (Plain t) = t
plainText (Span _ xs) = T.concat (map plainText xs)
plainText (GlossNode g) =
  case (glossMode g, glossTranslit g) of
    (VerticalLR, Just tr) -> tr
    (VerticalRL, Just tr) -> tr
    _                     -> glossNative g

-- | Computes the multiset of semantic tags in a 'RichText' tree for QA parity checks.
collectTags :: Ord tag => RichText tag -> Map tag Int
collectTags = go Map.empty
  where
    go acc (Plain _) = acc
    go acc (GlossNode _) = acc
    go acc (Span tag children) =
      let acc' = Map.insertWith (+) tag 1 acc
      in foldl' go acc' children

-- | Stratum 6: Translation reliability tier (lower is more authoritative).
data Tier
  = Tier0 -- ^ Canonical reference source catalog (e.g. en.ftl).
  | Tier1 -- ^ Human-authored or native-reviewed translation.
  | Tier2 -- ^ Human-edited MT or community-reviewed translation.
  | Tier3 -- ^ Unreviewed MT passing all kogaki-qa AST and plural gates.
  | Tier4 -- ^ Experimental, partial, or constructed-language catalog.
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | Origin metadata attached to a localized resource.
data Provenance
  = ReferenceSource
  | HumanAuthored !Text
  | HumanReviewedMT !Text
  | MachineTranslated !Text
  deriving stock (Eq, Ord, Show)

-- | Per-locale governance policy supporting endangered languages and regional fallbacks.
data LocalePolicy = LocalePolicy
  { lpTag                     :: !LocaleTag
    -- ^ Target BCP 47 / ISO 639-3 / Glottolog tag.
  , lpFallbackChain           :: ![LocaleTag]
    -- ^ Ordered regional fallback chain (e.g. dsb -> hsb -> de -> en).
  , lpTier                    :: !Tier
    -- ^ Current reliability tier of this catalog.
  , lpAllowMachineTranslation :: !Bool
    -- ^ Set to 'False' for endangered/revitalizing languages (hard NoMT gate).
  , lpAllowPartial            :: !Bool
    -- ^ If 'True', partial community catalogs pass kogaki-qa without failing.
  } deriving stock (Eq, Show)

-- | Returns 'True' when a catalog's reliability tier meets or exceeds @minTier@
-- (remembering 'Tier0' is highest reliability and 'Tier4' is lowest).
meetsMinTier :: Tier -> Tier -> Bool
meetsMinTier minTier actualTier = actualTier <= minTier

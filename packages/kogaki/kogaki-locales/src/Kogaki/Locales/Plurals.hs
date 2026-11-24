{-# LANGUAGE OverloadedStrings #-}

-- | Module: Kogaki.Locales.Plurals
-- Description: Zero-C pure-Haskell CLDR cardinal plural rules plus Sanskrit dual and conlangs
--
-- Implements Unicode LDML Part 3 plural operand evaluation (@i@, @v@, @f@)
-- in pure Haskell with zero @libicu@ dependency.
module Kogaki.Locales.Plurals
  ( PluralCategory(..)
  , PluralOperands(..)
  , operandsFromInt
  , primaryLanguageSubtag
  , evalCardinalPlural
  , requiredPluralCategories
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Kogaki.Ontology (LocaleTag(..))

-- | The six Unicode CLDR plural categories.
data PluralCategory
  = PluralZero
  | PluralOne
  | PluralTwo
  | PluralFew
  | PluralMany
  | PluralOther
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | Unicode LDML plural operands for a formatted decimal value.
data PluralOperands = PluralOperands
  { opIntPart      :: !Integer
    -- ^ @i@: integer digits of @abs(n)@.
  , opFracDigits   :: !Int
    -- ^ @v@: number of visible fraction digits (including trailing zeros).
  , opFracValue    :: !Integer
    -- ^ @f@: visible fraction digits as an integer (0 when @v == 0@).
  } deriving stock (Eq, Show)

-- | Constructs exact integer plural operands (@v = 0, f = 0@).
operandsFromInt :: Integer -> PluralOperands
operandsFromInt n = PluralOperands (abs n) 0 0

-- | Extracts the lowercased BCP 47 primary language subtag (e.g. @"mn-Mong"@ -> @"mn"@).
primaryLanguageSubtag :: LocaleTag -> Text
primaryLanguageSubtag (LocaleTag raw) =
  T.toLower (T.takeWhile (\c -> c /= '-' && c /= '_') (T.strip raw))

-- | Evaluates the cardinal 'PluralCategory' for a locale and formatted operands.
evalCardinalPlural :: LocaleTag -> PluralOperands -> PluralCategory
evalCardinalPlural tag (PluralOperands i v f) =
  let lang = primaryLanguageSubtag tag
      nIsZero = i == 0 && f == 0
      nIsOne  = i == 1 && f == 0
      nIsTwo  = i == 2 && f == 0
      m10     = i `mod` 10
      m100    = i `mod` 100
  in case lang of
       -- Zero-inflection / single-category languages & conlangs
       "zh"  -> PluralOther
       "ja"  -> PluralOther
       "ko"  -> PluralOther
       "tok" -> PluralOther
       "jbo" -> PluralOther
       "ain" -> PluralOther

       -- Standard Germanic / Hellenic / Mongolian / Esperanto (i == 1 && v == 0)
       "en"  -> if i == 1 && v == 0 then PluralOne else PluralOther
       "de"  -> if i == 1 && v == 0 then PluralOne else PluralOther
       "el"  -> if nIsOne then PluralOne else PluralOther
       "mn"  -> if nIsOne then PluralOne else PluralOther
       "eo"  -> if nIsOne then PluralOne else PluralOther
       "es"  -> if nIsOne then PluralOne else PluralOther
       "it"  -> if i == 1 && v == 0 then PluralOne else PluralOther

       -- French & Portuguese: 0 and 1 share 'one'
       "fr"  -> if i == 0 || i == 1 then PluralOne else PluralOther
       "pt"  -> if i == 0 || i == 1 then PluralOne else PluralOther

       -- Hindi & Persian: i == 0 or n == 1 -> 'one'
       "hi"  -> if i == 0 || nIsOne then PluralOne else PluralOther
       "fa"  -> if i == 0 || nIsOne then PluralOne else PluralOther

       -- Classical Sanskrit: singular / dvivacana (dual) / plural
       "sa"
         | v == 0 && nIsOne -> PluralOne
         | v == 0 && nIsTwo -> PluralTwo
         | otherwise        -> PluralOther

       -- Sorbian (Upper & Lower): 4-way incl. dual
       "dsb" -> sorbianRule i v f
       "hsb" -> sorbianRule i v f

       -- Russian (East Slavic): one / few / many / other
       "ru"
         | v == 0 && m10 == 1 && m100 /= 11 -> PluralOne
         | v == 0 && m10 >= 2 && m10 <= 4 && not (m100 >= 12 && m100 <= 14) -> PluralFew
         | v == 0 && (m10 == 0 || (m10 >= 5 && m10 <= 9) || (m100 >= 11 && m100 <= 14)) -> PluralMany
         | otherwise -> PluralOther

       -- Arabic: all 6 CLDR categories
       "ar"
         | nIsZero -> PluralZero
         | nIsOne  -> PluralOne
         | nIsTwo  -> PluralTwo
         | v == 0 && m100 >= 3 && m100 <= 10 -> PluralFew
         | v == 0 && m100 >= 11 && m100 <= 99 -> PluralMany
         | otherwise -> PluralOther

       -- Safe universal fallback
       _ -> if i == 1 && v == 0 then PluralOne else PluralOther
  where
    sorbianRule intP fracV fracF
      | (fracV == 0 && intP `mod` 100 == 1) || fracF `mod` 100 == 1 = PluralOne
      | (fracV == 0 && intP `mod` 100 == 2) || fracF `mod` 100 == 2 = PluralTwo
      | (fracV == 0 && intP `mod` 100 `elem` [3, 4]) || fracF `mod` 100 `elem` [3, 4] = PluralFew
      | otherwise = PluralOther

-- | Returns the mandatory set of cardinal plural categories checked by @kogaki-qa@.
requiredPluralCategories :: LocaleTag -> Set PluralCategory
requiredPluralCategories tag =
  case primaryLanguageSubtag tag of
    "zh"  -> Set.singleton PluralOther
    "ja"  -> Set.singleton PluralOther
    "ko"  -> Set.singleton PluralOther
    "tok" -> Set.singleton PluralOther
    "jbo" -> Set.singleton PluralOther
    "ain" -> Set.singleton PluralOther
    "sa"  -> Set.fromList [PluralOne, PluralTwo, PluralOther]
    "dsb" -> Set.fromList [PluralOne, PluralTwo, PluralFew, PluralOther]
    "hsb" -> Set.fromList [PluralOne, PluralTwo, PluralFew, PluralOther]
    "ru"  -> Set.fromList [PluralOne, PluralFew, PluralMany, PluralOther]
    "ar"  -> Set.fromList [PluralZero, PluralOne, PluralTwo, PluralFew, PluralMany, PluralOther]
    _     -> Set.fromList [PluralOne, PluralOther]

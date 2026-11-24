{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Set as Set
import Kogaki.Locales.Plurals
  ( PluralCategory (..)
  , PluralOperands (..)
  , evalCardinalPlural
  , operandsFromInt
  , requiredPluralCategories
  )
import Kogaki.Locales.Registry
  ( builtinPolicies
  , resolveFallbackChain
  )
import Kogaki.Ontology (LocaleTag (..))
import System.Exit (exitFailure)

assert :: String -> Bool -> IO ()
assert desc True  = putStrLn ("  [PASS] " ++ desc)
assert desc False = do
  putStrLn ("  [FAIL] " ++ desc)
  exitFailure

main :: IO ()
main = do
  putStrLn "=== kogaki-locales Test Suite ==="

  putStrLn "--- Section 1: Cardinal Plural Rules ---"
  -- Russian: 1, 21 -> one; 2, 22 -> few; 5 -> many; 1.5 -> other
  assert "Russian 1 -> PluralOne" $
    evalCardinalPlural (LocaleTag "ru") (operandsFromInt 1) == PluralOne
  assert "Russian 21 -> PluralOne" $
    evalCardinalPlural (LocaleTag "ru") (operandsFromInt 21) == PluralOne
  assert "Russian 2 -> PluralFew" $
    evalCardinalPlural (LocaleTag "ru") (operandsFromInt 2) == PluralFew
  assert "Russian 22 -> PluralFew" $
    evalCardinalPlural (LocaleTag "ru") (operandsFromInt 22) == PluralFew
  assert "Russian 5 -> PluralMany" $
    evalCardinalPlural (LocaleTag "ru") (operandsFromInt 5) == PluralMany
  assert "Russian 1.5 (v=1, f=5) -> PluralOther" $
    evalCardinalPlural (LocaleTag "ru") (PluralOperands 1 1 5) == PluralOther

  -- Arabic: 0 -> zero, 1 -> one, 2 -> two, 3..10 -> few, 11..99 -> many, 100 -> other
  assert "Arabic 0 -> PluralZero" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 0) == PluralZero
  assert "Arabic 1 -> PluralOne" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 1) == PluralOne
  assert "Arabic 2 -> PluralTwo" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 2) == PluralTwo
  assert "Arabic 5 -> PluralFew" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 5) == PluralFew
  assert "Arabic 50 -> PluralMany" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 50) == PluralMany
  assert "Arabic 100 -> PluralOther" $
    evalCardinalPlural (LocaleTag "ar") (operandsFromInt 100) == PluralOther

  -- Classical Sanskrit: 1 -> one, 2 -> two (dvivacana), 3 -> other
  assert "Sanskrit 1 -> PluralOne" $
    evalCardinalPlural (LocaleTag "sa-Deva") (operandsFromInt 1) == PluralOne
  assert "Sanskrit 2 -> PluralTwo" $
    evalCardinalPlural (LocaleTag "sa-Deva") (operandsFromInt 2) == PluralTwo
  assert "Sanskrit 3 -> PluralOther" $
    evalCardinalPlural (LocaleTag "sa-Deva") (operandsFromInt 3) == PluralOther

  -- Hindi: 0, 1 -> one, 2 -> other
  assert "Hindi 0 -> PluralOne" $
    evalCardinalPlural (LocaleTag "hi") (operandsFromInt 0) == PluralOne
  assert "Hindi 1 -> PluralOne" $
    evalCardinalPlural (LocaleTag "hi") (operandsFromInt 1) == PluralOne
  assert "Hindi 2 -> PluralOther" $
    evalCardinalPlural (LocaleTag "hi") (operandsFromInt 2) == PluralOther

  -- English: 1 -> one, 1.0 (v=1) -> other
  assert "English 1 -> PluralOne" $
    evalCardinalPlural (LocaleTag "en") (operandsFromInt 1) == PluralOne
  assert "English 1.0 -> PluralOther" $
    evalCardinalPlural (LocaleTag "en") (PluralOperands 1 1 0) == PluralOther

  -- Conlangs: tok, jbo -> other
  assert "Toki Pona 1 -> PluralOther" $
    evalCardinalPlural (LocaleTag "tok") (operandsFromInt 1) == PluralOther
  assert "Lojban 1 -> PluralOther" $
    evalCardinalPlural (LocaleTag "jbo") (operandsFromInt 1) == PluralOther

  putStrLn "--- Section 2: Required Categories ---"
  assert "Arabic requires all 6 categories" $
    requiredPluralCategories (LocaleTag "ar") == Set.fromList [PluralZero, PluralOne, PluralTwo, PluralFew, PluralMany, PluralOther]
  assert "Russian requires 4 categories" $
    requiredPluralCategories (LocaleTag "ru") == Set.fromList [PluralOne, PluralFew, PluralMany, PluralOther]
  assert "Sanskrit requires 3 categories (One, Two, Other)" $
    requiredPluralCategories (LocaleTag "sa") == Set.fromList [PluralOne, PluralTwo, PluralOther]

  putStrLn "--- Section 3: Regional Fallback Chains ---"
  assert "dsb resolves dsb -> hsb -> de -> en" $
    resolveFallbackChain builtinPolicies (LocaleTag "dsb") ==
      [LocaleTag "dsb", LocaleTag "hsb", LocaleTag "de", LocaleTag "en"]
  assert "quz resolves quz -> es -> en" $
    resolveFallbackChain builtinPolicies (LocaleTag "quz") ==
      [LocaleTag "quz", LocaleTag "es", LocaleTag "en"]
  assert "Subtag truncation: de-AT -> de -> en" $
    resolveFallbackChain builtinPolicies (LocaleTag "de-AT") ==
      [LocaleTag "de-AT", LocaleTag "de", LocaleTag "en"]

  putStrLn "=== All kogaki-locales tests passed! ==="

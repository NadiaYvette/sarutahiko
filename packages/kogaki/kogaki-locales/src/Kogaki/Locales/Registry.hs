{-# LANGUAGE OverloadedStrings #-}

-- | Module: Kogaki.Locales.Registry
-- Description: Builtin locale registry, writing modes, and regional fallback chain resolver
--
-- Provides default 'LocalePolicy' and 'WritingMode' configurations for natural,
-- endangered, and constructed languages, alongside a robust BCP 47 truncation
-- fallback chain resolver with cycle protection.
module Kogaki.Locales.Registry
  ( builtinPolicies
  , builtinWritingModes
  , resolveFallbackChain
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Kogaki.Ontology
  ( LocalePolicy (..)
  , LocaleTag (..)
  , Tier (..)
  , WritingMode (..)
  )

-- | Default writing modes for registered locales.
builtinWritingModes :: Map LocaleTag WritingMode
builtinWritingModes = Map.fromList
  [ -- Vertical scripts
    (LocaleTag "mn-Mong", VerticalLR)
  , -- RTL scripts
    (LocaleTag "ar", HorizontalRTL)
  , (LocaleTag "fa", HorizontalRTL)
  , -- Standard LTR scripts
    (LocaleTag "en", HorizontalLTR)
  , (LocaleTag "de", HorizontalLTR)
  , (LocaleTag "es", HorizontalLTR)
  , (LocaleTag "fr", HorizontalLTR)
  , (LocaleTag "it", HorizontalLTR)
  , (LocaleTag "pt", HorizontalLTR)
  , (LocaleTag "zh-Hans", HorizontalLTR)
  , (LocaleTag "zh-Hant", HorizontalLTR)
  , (LocaleTag "ja", HorizontalLTR)
  , (LocaleTag "ko", HorizontalLTR)
  , (LocaleTag "mn-Cyrl", HorizontalLTR)
  , (LocaleTag "ru", HorizontalLTR)
  , (LocaleTag "el", HorizontalLTR)
  , (LocaleTag "hi", HorizontalLTR)
  , (LocaleTag "sa-Deva", HorizontalLTR)
  , (LocaleTag "sa-Latn", HorizontalLTR)
  , (LocaleTag "dsb", HorizontalLTR)
  , (LocaleTag "hsb", HorizontalLTR)
  , (LocaleTag "quz", HorizontalLTR)
  , (LocaleTag "ain", HorizontalLTR)
  , (LocaleTag "eo", HorizontalLTR)
  , (LocaleTag "eo-Cyrl", HorizontalLTR)
  , (LocaleTag "tok", HorizontalLTR)
  , (LocaleTag "tok-x-sitelen-pona", HorizontalLTR)
  , (LocaleTag "jbo", HorizontalLTR)
  , (LocaleTag "jbo-x-zbalermorna", HorizontalLTR)
  , (LocaleTag "art-x-toaq", HorizontalLTR)
  , (LocaleTag "art-x-toaq-derani", HorizontalLTR)
  , (LocaleTag "qya-Teng", HorizontalLTR)
  , (LocaleTag "sjn-Teng", HorizontalLTR)
  ]

-- | Default locale governance policies.
builtinPolicies :: Map LocaleTag LocalePolicy
builtinPolicies = Map.fromList
  [ -- Canonical reference
    mkPolicy "en" [] Tier0 True False
    -- Natural repertoire (Tier1/2)
  , mkPolicy "de" ["en"] Tier1 True False
  , mkPolicy "es" ["en"] Tier1 True False
  , mkPolicy "fr" ["en"] Tier1 True False
  , mkPolicy "it" ["en"] Tier1 True False
  , mkPolicy "pt" ["en"] Tier1 True False
  , mkPolicy "zh-Hans" ["en"] Tier1 True False
  , mkPolicy "zh-Hant" ["zh-Hans", "en"] Tier1 True False
  , mkPolicy "ja" ["en"] Tier1 True False
  , mkPolicy "ko" ["en"] Tier1 True False
  , mkPolicy "mn-Cyrl" ["en"] Tier1 True False
  , mkPolicy "mn-Mong" ["mn-Cyrl", "en"] Tier1 True False
  , mkPolicy "ru" ["en"] Tier1 True False
  , mkPolicy "el" ["en"] Tier1 True False
  , mkPolicy "hi" ["en"] Tier1 True False
  , mkPolicy "sa-Deva" ["hi", "en"] Tier1 True False
  , mkPolicy "sa-Latn" ["sa-Deva", "en"] Tier1 True False
  , mkPolicy "fa" ["en"] Tier1 True False
  , mkPolicy "ar" ["en"] Tier1 True False
    -- Endangered exemplars with hard NoMT (lpAllowMachineTranslation = False, lpAllowPartial = True)
  , mkPolicy "dsb" ["hsb", "de", "en"] Tier2 False True
  , mkPolicy "hsb" ["de", "en"] Tier2 False True
  , mkPolicy "quz" ["es", "en"] Tier2 False True
  , mkPolicy "ain" ["ja", "en"] Tier2 False True
    -- Constructed languages (Tier4)
  , mkPolicy "eo" ["en"] Tier4 True True
  , mkPolicy "eo-Cyrl" ["eo", "en"] Tier4 True True
  , mkPolicy "tok" ["en"] Tier4 True True
  , mkPolicy "tok-x-sitelen-pona" ["tok", "en"] Tier4 True True
  , mkPolicy "jbo" ["en"] Tier4 True True
  , mkPolicy "jbo-x-zbalermorna" ["jbo", "en"] Tier4 True True
  , mkPolicy "art-x-toaq" ["en"] Tier4 True True
  , mkPolicy "art-x-toaq-derani" ["art-x-toaq", "en"] Tier4 True True
  , mkPolicy "qya-Teng" ["en"] Tier4 True True
  , mkPolicy "sjn-Teng" ["en"] Tier4 True True
  ]
  where
    mkPolicy tag chain tier allowMT allowPart =
      (LocaleTag tag, LocalePolicy (LocaleTag tag) (map LocaleTag chain) tier allowMT allowPart)

-- | Resolves an ordered regional fallback chain for a given locale tag.
--
-- Incorporates:
-- 1. Explicit 'lpFallbackChain' entries defined in the policy.
-- 2. BCP 47 subtag truncation fallback (e.g. @"de-AT"@ -> @"de"@).
-- 3. Cycle prevention via visited tag set.
-- 4. Guaranteed terminal @"en"@ fallback.
resolveFallbackChain :: Map LocaleTag LocalePolicy -> LocaleTag -> [LocaleTag]
resolveFallbackChain policies startTag = reverse (go Set.empty [] [startTag])
  where
    go _ acc [] = acc
    go visited acc (t : ts)
      | Set.member t visited = go visited acc ts
      | otherwise =
          let visited' = Set.insert t visited
              acc' = t : acc
              -- Compute immediate fallbacks for t
              nextTargets =
                case Map.lookup t policies of
                  Just pol -> lpFallbackChain pol
                  Nothing  ->
                    -- Subtag truncation: if t contains '-', try truncating
                    case truncateSubtag t of
                      Just truncated | not (Set.member truncated visited') -> [truncated, LocaleTag "en"]
                      _ -> [LocaleTag "en"]
          in go visited' acc' (ts ++ filter (\x -> not (Set.member x visited')) nextTargets)

    truncateSubtag (LocaleTag raw) =
      let parts = T.splitOn "-" raw
      in if length parts > 1
           then Just (LocaleTag (T.intercalate "-" (init parts)))
           else Nothing

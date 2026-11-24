{-# LANGUAGE OverloadedStrings #-}

-- | Module: Fluent.Polytropos.Schema
-- Description: Pure FTL catalog schema IR shared by TH synthesis, TcPlugin, and kogaki-qa
--
-- Represents the compile-time type-level projection of a Project Fluent (.ftl)
-- resource into closed @polytropos@ row metadata: message identifiers,
-- typed @$variable@ parameters, Stratum 4 semantic inline tag multisets,
-- and structural diffs against a reference catalog.
module Fluent.Polytropos.Schema
  ( -- * Parameter & Message Schema Types
    ParamType(..)
  , MessageSchema(..)
  , CatalogSchema(..)
  , CatalogDiff(..)
    -- * Annotation Parsing & Structural Diffing
  , mkEmptyCatalog
  , parseParamAnnotations
  , extractInlineTags
  , diffCatalogSchemas
  ) where

import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

-- | Statically inferred or annotated Haskell type for a Fluent @$variable@.
data ParamType
  = ParamText
    -- ^ Unformatted localized text fragment.
  | ParamVerbatim
    -- ^ Stratum 0 invariant token wrapped in FSI/PDI BiDi isolates.
  | ParamNumber
    -- ^ Locale-formatted numeric scalar (@NUMBER($x)@ or plural selector).
  | ParamDateTime
    -- ^ Locale-formatted timestamp (@DATETIME($x)@).
  | ParamCustom !Text
    -- ^ Domain newtype specified via @# \@param $x :: TypeName@.
  deriving stock (Eq, Ord, Show, Read)

-- | Schema of a single Fluent message (or @msg.attr@ compound key).
data MessageSchema = MessageSchema
  { msId         :: !Text
    -- ^ Canonical Fluent message identifier (e.g. @"unknown-flag"@).
  , msParams     :: !(Map Text ParamType)
    -- ^ Free @$variable@ names mapped to their static parameter types.
  , msInlineTags :: !(Map Text Int)
    -- ^ Multiset of Stratum 4 semantic tags (e.g. @"flag" -> 2@).
  , msAttributes :: !(Set Text)
    -- ^ Named Fluent attributes attached to this message.
  } deriving stock (Eq, Show)

-- | Complete schema extracted from a reference or localized @.ftl@ resource.
data CatalogSchema = CatalogSchema
  { csLocale   :: !Text
    -- ^ BCP 47 locale tag associated with this catalog.
  , csMessages :: !(Map Text MessageSchema)
    -- ^ Indexed message schemas keyed by Fluent message ID.
  , csTerms    :: !(Set Text)
    -- ^ Defined private @-term@ identifiers in this catalog.
  } deriving stock (Eq, Show)

-- | Structural discrepancies between a reference catalog (@en.ftl@) and a target locale.
data CatalogDiff = CatalogDiff
  { cdMissingMessages :: !(Set Text)
    -- ^ Reference messages absent from the target catalog.
  , cdExtraMessages   :: !(Set Text)
    -- ^ Messages present in target but undefined in reference.
  , cdParamMismatches :: !(Map Text (Set Text, Set Text))
    -- ^ Per-message @(missingVars, extraVars)@ discrepancies.
  , cdTagMismatches   :: !(Map Text (Map Text Int, Map Text Int))
    -- ^ Per-message @(expectedTags, actualTags)@ Stratum 4 drift.
  } deriving stock (Eq, Show)

-- | Constructs an empty catalog schema with the given locale tag.
mkEmptyCatalog :: Text -> CatalogSchema
mkEmptyCatalog loc = CatalogSchema loc Map.empty Set.empty

-- | Parses @# \@param $name :: Type@ directives from FTL comment lines.
parseParamAnnotations :: [Text] -> Map Text ParamType
parseParamAnnotations = foldl' step Map.empty
  where
    step acc rawLine =
      let line = T.strip (T.dropWhile (== '#') (T.strip rawLine))
      in case T.stripPrefix "@param" line of
           Nothing -> acc
           Just rest ->
             case T.breakOn "::" (T.strip rest) of
               (lhs, rhs)
                 | not (T.null rhs)
                 , Just varName <- T.stripPrefix "$" (T.strip lhs)
                 , let tyName = T.strip (T.drop 2 rhs)
                 , not (T.null varName) && not (T.null tyName)
                 -> Map.insert varName (parseTypeName tyName) acc
               _ -> acc

    parseTypeName "Text"     = ParamText
    parseTypeName "Verbatim" = ParamVerbatim
    parseTypeName "Int"      = ParamNumber
    parseTypeName "Double"   = ParamNumber
    parseTypeName "Number"   = ParamNumber
    parseTypeName "DateTime" = ParamDateTime
    parseTypeName "UTCTime"  = ParamDateTime
    parseTypeName custom     = ParamCustom custom

-- | Extracts opening Stratum 4 semantic tags (@<flag>@, @<code>@, @<emph>@, @<link>@)
-- from a rendered or raw Fluent pattern string into a multiset.
extractInlineTags :: Text -> Map Text Int
extractInlineTags = go Map.empty
  where
    go acc t = case T.breakOn "<" t of
      (_, rest) | T.null rest -> acc
      (_, rest) ->
        let afterLt = T.drop 1 rest
        in case T.breakOn ">" afterLt of
             (_, afterGt) | T.null afterGt -> acc
             (tagBody, afterGt) ->
               let clean = T.strip tagBody
                   tagName = T.takeWhile (\c -> c /= ' ' && c /= '/') clean
                   acc' =
                     if not (T.null clean)
                          && not ("/" `T.isPrefixOf` clean)
                          && not (T.null tagName)
                       then Map.insertWith (+) tagName 1 acc
                       else acc
               in go acc' (T.drop 1 afterGt)

-- | Computes all structural discrepancies between a reference catalog and a target catalog.
diffCatalogSchemas :: CatalogSchema -> CatalogSchema -> CatalogDiff
diffCatalogSchemas refCat tgtCat =
  let refMsgs = csMessages refCat
      tgtMsgs = csMessages tgtCat
      refKeys = Map.keysSet refMsgs
      tgtKeys = Map.keysSet tgtMsgs
      shared  = Map.intersectionWith (,) refMsgs tgtMsgs
      paramDiffs =
        Map.mapMaybe
          (\(r, t) ->
             let rk = Map.keysSet (msParams r)
                 tk = Map.keysSet (msParams t)
                 miss = Set.difference rk tk
                 extra = Set.difference tk rk
             in if Set.null miss && Set.null extra
                  then Nothing
                  else Just (miss, extra))
          shared
      tagDiffs =
        Map.mapMaybe
          (\(r, t) ->
             if msInlineTags r == msInlineTags t
               then Nothing
               else Just (msInlineTags r, msInlineTags t))
          shared
  in CatalogDiff
      { cdMissingMessages = Set.difference refKeys tgtKeys
      , cdExtraMessages   = Set.difference tgtKeys refKeys
      , cdParamMismatches = paramDiffs
      , cdTagMismatches   = tagDiffs
      }

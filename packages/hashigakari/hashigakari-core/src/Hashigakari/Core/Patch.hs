{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Hashigakari.Core.Patch
-- Description : RFC 7396 TriState patch diffing and application
--
-- Generic diff engine computing minimal TriState patch rows and
-- applying patches to extensible records per HASHIGAKARI_DESIGN.md §3.5.
--
-- === Intellectual Lineage & Attribution
-- This module implements the TriState patch algebra synthesized from:
-- * RFC 7396 (JSON Merge Patch)
-- * 'large-anon' (Edsko de Vries / Well-Typed) — row combinators
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Core.Patch
  ( -- * Diff and Patch Algebra
    diffRecords
  , applyPatch
  , patchModifiedCount
    -- * Pattern Synonyms for TriState
  , pattern Keep
  , pattern Clear
  , pattern Set
  ) where

import Data.Functor.Identity (Identity (..))
import Data.Proxy (Proxy (..))
import Data.Record.Anon (AllFields, K (..), KnownFields)
import qualified Data.Record.Anon.Advanced as Anon
import Data.Record.Anon.Advanced (Record, collapse, czipWith, reifyKnownFields)

import Sarutahiko.Records (TriState (..))

-- | Pattern synonym for omitted/unmodified field.
pattern Keep :: TriState a
pattern Keep = Absent

-- | Pattern synonym for explicit null.
pattern Clear :: TriState a
pattern Clear = PresentNull

-- | Pattern synonym for updated value.
pattern Set :: a -> TriState a
pattern Set x = Present x

{-# COMPLETE Keep, Clear, Set #-}

-- | Diff two materialized rows to compute the minimal RFC 7396 'TriState' patch.
-- Unmodified fields are 'Keep' ('Absent'); modified fields are 'Set' ('Present').
diffRecords
  :: forall r. AllFields r Eq
  => Record Identity r
  -> Record Identity r
  -> Record TriState r
diffRecords oldRow newRow =
  czipWith (Proxy @Eq) (\(Identity oldVal) (Identity newVal) ->
    if oldVal == newVal
      then Keep
      else Set newVal
  ) oldRow newRow

-- | Apply an RFC 7396 'TriState' patch to an existing record.
-- 'Keep' preserves existing value; 'Set x' overwrites with 'x';
-- 'Clear' for non-null types retains original or can be specialized.
applyPatch
  :: forall r.
     Record TriState r
  -> Record Identity r
  -> Record Identity r
applyPatch patch baseRow =
  Anon.zipWith (\p (Identity val) ->
    case p of
      Keep   -> Identity val
      Set x  -> Identity x
      Clear  -> Identity val
  ) patch baseRow

-- | Count the number of non-Keep fields in a patch record.
patchModifiedCount
  :: forall r. (KnownFields r)
  => Record TriState r
  -> Int
patchModifiedCount patch =
  let names = reifyKnownFields (Proxy @r)
      flags = Anon.zipWith (\_ p -> K (case p of Keep -> (0 :: Int); _ -> 1)) names patch
  in sum (collapse flags)

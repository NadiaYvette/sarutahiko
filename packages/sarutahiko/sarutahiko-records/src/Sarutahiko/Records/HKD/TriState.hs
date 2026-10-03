{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : Sarutahiko.Records.HKD.TriState
-- Description : Three-state presence functor satisfying contracts CA1–CA3
--
-- Differentiates between omitted fields ('Absent'), explicit nulls ('PresentNull'),
-- and active values ('Present a') per FIELDS_RECORDS_DESIGN.md §2.2.
module Sarutahiko.Records.HKD.TriState
  ( -- * The TriState Functor
    TriState (..)

    -- * Query Combinators
  , isAbsent
  , isPresentNull
  , isPresent

    -- * Conversions
  , toMaybe
  , fromMaybe
  , fromOptional
  , fromTriState
  ) where

import Control.Applicative (Alternative (..))

-- | HKD functor representing absence, explicit null, or valid presence (CA1).
--
-- Satisfies contracts:
-- - CA1: Exactly three constructors ('Absent', 'PresentNull', 'Present').
-- - CA2: Projection naturality and lossless round-trip under RFC 7396 merge patch semantics.
-- - CA3: Strictly no provenance state ('Defaulted' or 'Migrated' are forbidden).
data TriState a
  = Absent
    -- ^ Field was omitted / not present in the payload.
  | PresentNull
    -- ^ Field was explicitly set to null (e.g. JSON null or SQL NULL).
  | Present !a
    -- ^ Field is present with an active value.
  deriving stock (Eq, Ord, Show, Read, Functor, Foldable, Traversable)

instance Applicative TriState where
  pure = Present

  Present f <*> Present x = Present (f x)
  Absent    <*> _         = Absent
  _         <*> Absent    = Absent
  PresentNull <*> _       = PresentNull
  _         <*> PresentNull = PresentNull

instance Alternative TriState where
  empty = Absent

  Absent <|> r = r
  l      <|> _ = l

-- | True if the field was omitted.
isAbsent :: TriState a -> Bool
isAbsent Absent = True
isAbsent _      = False

-- | True if the field was explicitly provided as null.
isPresentNull :: TriState a -> Bool
isPresentNull PresentNull = True
isPresentNull _           = False

-- | True if the field carries a present, non-null value.
isPresent :: TriState a -> Bool
isPresent (Present _) = True
isPresent _           = False

-- | Collapse 'TriState' into standard 'Maybe', treating both 'Absent' and 'PresentNull' as 'Nothing'.
toMaybe :: TriState a -> Maybe a
toMaybe (Present a) = Just a
toMaybe _           = Nothing

-- | Convert standard 'Maybe' into 'TriState', mapping 'Nothing' to 'PresentNull'.
fromMaybe :: Maybe a -> TriState a
fromMaybe Nothing  = PresentNull
fromMaybe (Just a) = Present a

-- | Convert optional 'Maybe' into 'TriState', mapping 'Nothing' to 'Absent'.
fromOptional :: Maybe a -> TriState a
fromOptional Nothing  = Absent
fromOptional (Just a) = Present a

-- | Fold a 'TriState' with explicit handlers for each branch.
fromTriState :: r -> r -> (a -> r) -> TriState a -> r
fromTriState onAbsent _ _ Absent             = onAbsent
fromTriState _ onNull _ PresentNull          = onNull
fromTriState _ _ onPresent (Present a)       = onPresent a

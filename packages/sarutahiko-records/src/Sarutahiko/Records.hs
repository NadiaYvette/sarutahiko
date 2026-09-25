-- |
-- Module      : Sarutahiko.Records
-- Description : HKD functors, envelopes, and combinators
module Sarutahiko.Records
  ( -- * Functor Family
    TriState (..)
  ) where

-- | HKD functor representing JSON merge-patch presence:
-- absent from payload, present as null (delete), or present with value.
data TriState a
  = Absent
  | Null
  | Present !a
  deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)

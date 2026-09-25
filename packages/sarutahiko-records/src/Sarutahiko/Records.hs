{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE PatternSynonyms #-}

-- |
-- Module      : Sarutahiko.Records
-- Description : HKD functors, envelopes, and combinators
--
-- Top-level entry point for 'sarutahiko-records', defining the blessed
-- 'TriState' absence functor (CA1–CA3), 'WireEnvelope' with unknown-field
-- preservation (E3–E4), and the right-biased override operator '(⊕)' (L1–L6).
module Sarutahiko.Records
  ( -- * HKD Functors
    module Sarutahiko.Records.HKD.TriState

    -- * Wire Envelopes
  , module Sarutahiko.Records.Envelope

    -- * Row Combinators
  , module Sarutahiko.Records.Combinators

    -- * Anonymous Record Re-exports
  , Record
  , pattern (:=)
  , Row
  , Merge
  , SubRow
  , RowHasField
  , AllFields
  , KnownFields
  , Field
  ) where

import Data.Record.Anon
  ( AllFields
  , Field
  , KnownFields
  , Merge
  , Row
  , RowHasField
  , SubRow
  , pattern (:=)
  )
import Data.Record.Anon.Advanced (Record)

import Sarutahiko.Records.Combinators
import Sarutahiko.Records.Envelope
import Sarutahiko.Records.HKD.TriState

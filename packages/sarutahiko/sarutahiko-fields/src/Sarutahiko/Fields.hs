-- |
-- Module      : Sarutahiko.Fields
-- Description : First-class field datums and field registry
--
-- Top-level entry point for the 'sarutahiko-fields' package, implementing
-- contracts CD1–CD2 from FIELDS_RECORDS_DESIGN.md §3.
--
-- === Intellectual Lineage & Attribution
-- This module implements the "define a field exactly once" doctrine, synthesized from:
-- * 'large-records' & 'large-anon' (Edsko de Vries / Well-Typed) — typelet field indexing
-- * 'vinyl' (Anthony Cowley) — extensible universe-polymorphic field tagging
-- * 'docrecords' (Yves Parès, Faura et al.) — field metadata and documentation binding
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Fields
  ( -- * Field Datums
    module Sarutahiko.Fields.Datum

    -- * Field Witnesses
  , module Sarutahiko.Fields.Witness

    -- * Field Registry
  , module Sarutahiko.Fields.Registry
  ) where

import Sarutahiko.Fields.Datum
import Sarutahiko.Fields.Registry
import Sarutahiko.Fields.Witness

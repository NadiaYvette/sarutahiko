-- |
-- Module      : Sarutahiko.Fields
-- Description : First-class field datums and field registry
--
-- Top-level entry point for the 'sarutahiko-fields' package, implementing
-- contracts CD1–CD2 from FIELDS_RECORDS_DESIGN.md §3.
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

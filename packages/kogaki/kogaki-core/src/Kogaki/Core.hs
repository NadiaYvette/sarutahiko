-- |
-- Module      : Kogaki.Core
-- Description : Pervasive string, Unicode normalization, and i18n foundation
--
-- Anchors the canonical text representation directly above 'Data.String.IsString'
-- and re-exports the structured 'LogicalString' abstraction.
module Kogaki.Core
  ( -- * Core Logical String
    module Kogaki.Core.String

    -- * Core Re-exports
  , module Data.String
  ) where

import Data.String (IsString (..))
import Kogaki.Core.String

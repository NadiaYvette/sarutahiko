-- |
-- Module      : Kogaki.Core
-- Description : Pervasive string, Unicode normalization, and i18n foundation
--
-- Anchors the canonical text representation directly above 'Data.String.IsString'.
module Kogaki.Core
  ( -- * Core Re-exports
    module Data.String
  ) where

import Data.String (IsString (..))

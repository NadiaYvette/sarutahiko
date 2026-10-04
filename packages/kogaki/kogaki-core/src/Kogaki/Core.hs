-- |
-- Module      : Kogaki.Core
-- Description : Pervasive string, Unicode normalization, and i18n foundation
--
-- Anchors the canonical text representation directly above 'Data.String.IsString'
-- and re-exports the structured 'LogicalString' abstraction.
--
-- === Intellectual Lineage & Attribution
-- This module draws text validation and slicing foundations from:
-- * 'text' (Bryan O'Sullivan, Jasper Van der Jeugt) — UTF-8 slicing and verification
-- * 'aeson' (Bryan O'Sullivan et al.) — RFC 8259 string escape semantics
-- * 'mono-traversable' (Michael Snoyman) — NonNull non-emptiness guarantees
-- See @NOTICE.md@ at the repository root.
module Kogaki.Core
  ( -- * Core Logical String
    module Kogaki.Core.String

    -- * Core Re-exports
  , module Data.String
  ) where

import Data.String (IsString (..))
import Kogaki.Core.String

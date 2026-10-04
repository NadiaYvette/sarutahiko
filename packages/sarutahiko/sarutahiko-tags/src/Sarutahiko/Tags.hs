-- |
-- Module      : Sarutahiko.Tags
-- Description : Code intelligence tag extraction and ctags indexing
--
-- Exports definition, type, and symbol extraction for Haskell, C, and
-- procedural sources with Universal Ctags and Vi/Ex formatting.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts
-- pioneered by:
-- * Universal Ctags (Darren Hiebert, Masatake Yamato et al.) — tag format, kinds, and scope tracking
-- * Tree-sitter & ctags AST extractors — incremental symbol navigation
-- * Smirk (Nadia Yvette Chambers) — deterministic regex and lexical matching patterns
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Tags
  ( module Sarutahiko.Tags.Types
  , module Sarutahiko.Tags.Extractor
  , module Sarutahiko.Tags.Format
  ) where

import Sarutahiko.Tags.Extractor
import Sarutahiko.Tags.Format
import Sarutahiko.Tags.Types

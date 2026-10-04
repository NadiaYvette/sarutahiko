-- |
-- Module      : Hashigakari.Core
-- Description : Row-typed relational query AST and extensible record schemas
--
-- Top-level module for 'hashigakari-core' providing relational query AST,
-- column descriptors, typed expressions, and TriState merge patches
-- per HASHIGAKARI_DESIGN.md.
--
-- === Intellectual Lineage & Attribution
-- This package synthesizes database query principles pioneered by:
-- * 'beam' (Travis Whitaker) — relational schema and query composition (see LICENSES/NOTICE-beam.txt)
-- * 'hasql' (Nikita Volkov) — applicative row decoding directly into strongly-typed structures
-- * 'large-anon' (Edsko de Vries / Well-Typed) — O(1) compile-time extensible anonymous records
-- * RFC 7396 — TriState merge patch algebra
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Core
  ( module Hashigakari.Core.Column
  , module Hashigakari.Core.Expr
  , module Hashigakari.Core.AST
  , module Hashigakari.Core.Patch
  ) where

import Hashigakari.Core.AST
import Hashigakari.Core.Column
import Hashigakari.Core.Expr
import Hashigakari.Core.Patch

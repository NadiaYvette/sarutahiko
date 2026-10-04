-- |
-- Module      : Hashigakari.Syntax
-- Description : Dialect-indexed SQL compilation and capability ceilings
--
-- Top-level module for 'hashigakari-syntax' providing SQL compilation,
-- parameter binding, and type-level capability checks per HASHIGAKARI_DESIGN.md.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'beam' (Travis Whitaker) — dialect syntax engines and type-level backends
-- * 'hasql' (Nikita Volkov) — parameterized query templates and binary decoders
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Syntax
  ( module Hashigakari.Syntax.Dialect
  , module Hashigakari.Syntax.Render
  , module Hashigakari.Syntax.Compile
  ) where

import Hashigakari.Syntax.Compile
import Hashigakari.Syntax.Dialect
import Hashigakari.Syntax.Render

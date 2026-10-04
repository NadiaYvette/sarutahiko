-- |
-- Module      : Yamaarashi.Spec
-- Description : Specification extraction, static over-approximation, and task subdivision
--
-- Top-level module for 'yamaarashi-spec' providing Pass 1 static dependency
-- analysis via 'Control.Selective.Over' and corecursive task subdivision via
-- 'recursion-schemes' per YAMAARASHI_DESIGN.md.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and synthesis of:
-- * 'recursion-schemes' (Edward Kmett, Eric Mertens) — catamorphisms and anamorphic/hylomorphic task subdivision
-- * 'selective' (Andrey Mokhov et al.) — static over-approximation via 'Control.Selective.Over'
-- See @NOTICE.md@ at the repository root.
module Yamaarashi.Spec
  ( module Yamaarashi.Spec.Types
  , module Yamaarashi.Spec.VirtualTree
  , module Yamaarashi.Spec.Subdivide
  ) where

import Yamaarashi.Spec.Subdivide
import Yamaarashi.Spec.Types
import Yamaarashi.Spec.VirtualTree

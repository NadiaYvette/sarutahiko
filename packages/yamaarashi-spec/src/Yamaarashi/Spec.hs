-- |
-- Module      : Yamaarashi.Spec
-- Description : Specification extraction, static over-approximation, and task subdivision
--
-- Top-level module for 'yamaarashi-spec' providing Pass 1 static dependency
-- analysis via 'Control.Selective.Over' and corecursive task subdivision via
-- 'recursion-schemes' per YAMAARASHI_DESIGN.md.
module Yamaarashi.Spec
  ( module Yamaarashi.Spec.Types
  , module Yamaarashi.Spec.VirtualTree
  , module Yamaarashi.Spec.Subdivide
  ) where

import Yamaarashi.Spec.Subdivide
import Yamaarashi.Spec.Types
import Yamaarashi.Spec.VirtualTree

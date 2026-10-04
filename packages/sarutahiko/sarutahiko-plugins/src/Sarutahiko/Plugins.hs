-- |
-- Module      : Sarutahiko.Plugins
-- Description : Dynamic plugin loader and capability supervisor
--
-- Top-level entry point for the Sarutahiko plugin management engine.
--
-- === Intellectual Lineage & Attribution
-- This module adapts the plugin discovery and capability grant model of:
-- * Hermes Agent (Nous Research) — plugin loader, capability grants, and kill-lists
-- See @NOTICE.md@ and @LICENSES/NOTICE-hermes.txt@ at the repository root.
module Sarutahiko.Plugins
  ( module Sarutahiko.Plugins.Types
  , module Sarutahiko.Plugins.Loader
  ) where

import Sarutahiko.Plugins.Loader
import Sarutahiko.Plugins.Types

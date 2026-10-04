-- |
-- Module      : Sarutahiko.Hooks
-- Description : Shell-hook execution, consent allowlists, and supervision
--
-- Top-level entry point for the Sarutahiko hook supervisor engine.
--
-- === Intellectual Lineage & Attribution
-- This module adapts shell hook patterns from:
-- * Hermes Agent (Nous Research) — shell-hook conventions and consent allowlists
-- * 'typed-process' (Michael Snoyman) — safe process supervision
-- See @NOTICE.md@ and @LICENSES/NOTICE-hermes.txt@ at the repository root.
module Sarutahiko.Hooks
  ( module Sarutahiko.Hooks.Types
  , module Sarutahiko.Hooks.Allowlist
  , module Sarutahiko.Hooks.Supervisor
  ) where

import Sarutahiko.Hooks.Allowlist
import Sarutahiko.Hooks.Supervisor
import Sarutahiko.Hooks.Types

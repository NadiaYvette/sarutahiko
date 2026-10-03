-- |
-- Module      : Sarutahiko.Hooks
-- Description : Shell-hook execution, consent allowlists, and supervision
--
-- Top-level entry point for the Sarutahiko hook supervisor engine.
module Sarutahiko.Hooks
  ( module Sarutahiko.Hooks.Types
  , module Sarutahiko.Hooks.Allowlist
  , module Sarutahiko.Hooks.Supervisor
  ) where

import Sarutahiko.Hooks.Allowlist
import Sarutahiko.Hooks.Supervisor
import Sarutahiko.Hooks.Types

-- |
-- Module      : Sarutahiko.Effect.TestKit
-- Description : Dual-interpreter parity testkit and verification suite
--
-- Top-level re-export for 'sarutahiko-effect-testkit' per PHASE_0_PLAN.md TP-0.6.
module Sarutahiko.Effect.TestKit
  ( module Sarutahiko.Effect.Testkit.Parity
  , module Sarutahiko.Effect.Testkit.STM
  ) where

import Sarutahiko.Effect.Testkit.Parity
import Sarutahiko.Effect.Testkit.STM

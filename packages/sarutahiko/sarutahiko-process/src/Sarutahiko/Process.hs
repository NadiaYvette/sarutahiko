-- |
-- Module      : Sarutahiko.Process
-- Description : Subprocess supervisor and tagless capability façade
--
-- Re-exports the canonical Process GADT from 'sarutahiko-effect-signatures',
-- the open 'MonadProcess' capability typeclass, and pure POSIX supervisor.
--
-- === Intellectual Lineage & Attribution
-- This module adapts process supervision paradigms from:
-- * 'typed-process' (Michael Snoyman, MIT) — typed process handles and safe cleanup
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Process
  ( module Sarutahiko.Effect.Process
  , module Sarutahiko.Process.Capability
  , module Sarutahiko.Process.Supervisor
  ) where

import Sarutahiko.Effect.Process
import Sarutahiko.Process.Capability
import Sarutahiko.Process.Supervisor

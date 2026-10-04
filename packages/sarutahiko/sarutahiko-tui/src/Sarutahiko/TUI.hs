-- |
-- Module      : Sarutahiko.TUI
-- Description : Terminal user interface for Sarutahiko agent sessions
--
-- Exposes pure state machines, declarative rendering widgets, and
-- JSON-RPC integration for interactive terminal interactions.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts
-- pioneered by:
-- * Hermes Agent (Nous Research) — terminal user experience and session display
-- * Brick & Vty (Jonathan Daugherty) — declarative widget trees and terminal event loops
-- * Kuroko / Keiro (Nadeem Bitar) — row-typed UI state projections over algebraic effects
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.TUI
  ( module Sarutahiko.TUI.Types
  , module Sarutahiko.TUI.Render
  , module Sarutahiko.TUI.Loop
  ) where

import Sarutahiko.TUI.Loop
import Sarutahiko.TUI.Render
import Sarutahiko.TUI.Types

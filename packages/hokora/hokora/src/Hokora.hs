-- |
-- Module      : Hokora
-- Description : Phase 1.5 Hokora vertical slice proving the Skinny Spine protocol
--
-- Top-level umbrella module re-exporting core domain types, the autonomous ReAct
-- turn program, and the conversation-tail reducer per HOKORA_SPEC.md.
--
-- === Intellectual Lineage & Attribution
-- This module proves the skinny spine protocol, drawing architectural lineage from:
-- * The Keiro ecosystem (Nadeem Bitar) — event-sourced replay and state machines
-- * SQLite (Public Domain) — embedded transactional persistence
-- See @NOTICE.md@ at the repository root.
module Hokora
  ( module Hokora.Types
  , module Hokora.Turn
  , module Hokora.Reducer
  ) where

import Hokora.Reducer
import Hokora.Turn
import Hokora.Types

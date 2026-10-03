-- |
-- Module      : Hokora
-- Description : Phase 1.5 Hokora vertical slice proving the Skinny Spine protocol
--
-- Top-level umbrella module re-exporting core domain types, the autonomous ReAct
-- turn program, and the conversation-tail reducer per HOKORA_SPEC.md.
module Hokora
  ( module Hokora.Types
  , module Hokora.Turn
  , module Hokora.Reducer
  ) where

import Hokora.Reducer
import Hokora.Turn
import Hokora.Types

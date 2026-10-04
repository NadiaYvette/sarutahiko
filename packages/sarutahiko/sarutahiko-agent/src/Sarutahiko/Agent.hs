-- |
-- Module      : Sarutahiko.Agent
-- Description : Full Hermes-style autonomous agent core
--
-- Top-level entry point for the Sarutahiko autonomous agent core.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts from:
-- * Hermes Agent (Nous Research) — core turn loop, tool execution architecture, and prompt-cache safety
-- * ReAct paradigm (Shunyu Yao et al.) — interleaved Thought/Action/Observation stepping
-- * The Keiro ecosystem (Nadeem Bitar) — foundational agent design patterns
-- See @NOTICE.md@ and @LICENSES/NOTICE-hermes.txt@ at the repository root.
module Sarutahiko.Agent
  ( module Sarutahiko.Agent.Registry
  , module Sarutahiko.Agent.Turn
  , module Sarutahiko.Agent.Loop
  , module Sarutahiko.Agent.Tools
  , module Sarutahiko.Agent.Live
  ) where

import Sarutahiko.Agent.Live
import Sarutahiko.Agent.Loop
import Sarutahiko.Agent.Registry
import Sarutahiko.Agent.Tools
import Sarutahiko.Agent.Turn

-- |
-- Module      : Utai
-- Description : Canonical LLM substrate and ModelAPI facade
--
-- Top-level entrypoint for 'utai' (Noh: 謡, the chant itself) per
-- LLM_SUBSTRATE_DESIGN.md and DECISION-005. Provides the neutral 'ModelAPI'
-- effect signature, open 'MonadModelAPI' capability typeclass, zero-token local
-- provider profiles, zero-Aeson wire codecs, and the deterministic 'utai-mock' carrier.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and synthesis of:
-- * 'baikai' (Nadeem Bitar) — provider laws (L1 terminal chunk, L2 usage monoid,
--   L3 option honesty) and provider error taxonomy
-- * OpenAI & Anthropic wire specifications — streaming chunk framing and payload protocols
-- See @NOTICE.md@ at the repository root.
module Utai
  ( module Utai.Types
  , module Utai.Capability
  , module Utai.Mock
  , module Utai.Wire
  , module Utai.Client
  ) where

import Utai.Capability
import Utai.Client
import Utai.Mock
import Utai.Types
import Utai.Wire

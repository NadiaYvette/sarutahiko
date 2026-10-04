-- |
-- Module      : Sarutahiko.Gateway
-- Description : Multi-platform chat gateway adapter
--
-- Provides platform abstraction (Telegram, Discord, Slack, Webhooks),
-- reified 'GatewayEffect', and tagless capabilities.
--
-- === Intellectual Lineage & Attribution
-- This module is an intellectual derivation and architectural synthesis of concepts
-- pioneered by:
-- * Kuroko / Keiro (Nadeem Bitar) — multi-surface gateway routing and algebraic effects
-- * Conduit (Michael Snoyman) — bracketed resource streaming and socket lifecycles
-- * Hermes Agent (Nous Research) — multi-client conversational surfaces
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Gateway
  ( module Sarutahiko.Gateway.Types
  , module Sarutahiko.Gateway.Effect
  , module Sarutahiko.Gateway.Interpreters
  ) where

import Sarutahiko.Gateway.Effect
import Sarutahiko.Gateway.Interpreters
import Sarutahiko.Gateway.Types

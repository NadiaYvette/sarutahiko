-- |
-- Module      : Sarutahiko.Format.Dhall
-- Description : Row-typed Dhall configuration bridge to large-anon extensible records
--
-- Top-level entry point for 'sarutahiko-format-dhall' mapping Dhall's typed records
-- directly to 'large-anon' anonymous rows without rewriting the upstream evaluator
-- per HASHIGAKARI_DESIGN.md and DECISION-004.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'dhall' (Gabriel Gonzalez) — statically typed, non-Turing-complete configuration language
-- * 'large-anon' (Edsko de Vries / Well-Typed) — extensible anonymous records
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Format.Dhall
  ( module Sarutahiko.Format.Dhall.Types
  , module Sarutahiko.Format.Dhall.Parser
  , module Sarutahiko.Format.Dhall.Render
  , module Sarutahiko.Format.Dhall.Bridge
  ) where

import Sarutahiko.Format.Dhall.Bridge
import Sarutahiko.Format.Dhall.Parser
import Sarutahiko.Format.Dhall.Render
import Sarutahiko.Format.Dhall.Types

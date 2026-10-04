-- |
-- Module      : Yamaarashi.Flow
-- Description : Selective task DAG orchestrator and Build Systems à la Carte scheduler
--
-- Top-level module for 'yamaarashi-flow' exposing the Selective workflow AST,
-- algebraic graph scheduler with memoization and early cutoff, and tagless
-- capability typeclasses under the Façade Pattern per YAMAARASHI_DESIGN.md.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes task caching and workflow execution concepts from:
-- * 'porcupine' & 'kernmantle' (Yves Parès, Faura et al.) — pipeline caching and virtual tree filesystems
-- * 'funflow' (Tom Nielsen, Andreas Herrmann / Tweag I/O) — functional workflow graphs
-- * 'selective' (Andrey Mokhov et al.) — Selective Applicative Functors for static over-approximation
-- * 'algebraic-graphs' (Andrey Mokhov) — algebraic graph DAG representation
-- See @NOTICE.md@ at the repository root.
module Yamaarashi.Flow
  ( module Yamaarashi.Flow.Types
  , module Yamaarashi.Flow.Scheduler
  , module Yamaarashi.Flow.Capability
  ) where

import Yamaarashi.Flow.Capability
import Yamaarashi.Flow.Scheduler
import Yamaarashi.Flow.Types

-- |
-- Module      : Hashigakari.Hasql
-- Description : PostgreSQL execution backend, connection pooling, and existential row steppers
--
-- Top-level module for 'hashigakari-hasql' providing PostgreSQL execution,
-- connection pool brackets, and existential Stepper streaming per HASHIGAKARI_DESIGN.md.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql' (Nikita Volkov) — PostgreSQL binary protocol and connection pooling
-- * 'yamaarashi' — canonical existential Stepper streaming
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql
  ( module Hashigakari.Hasql.Types
  , module Hashigakari.Hasql.Pool
  , module Hashigakari.Hasql.Stepper
  , module Hashigakari.Hasql.Effect
  , module Hashigakari.Hasql.Interpreters
  ) where

import Hashigakari.Hasql.Effect
import Hashigakari.Hasql.Interpreters
import Hashigakari.Hasql.Pool
import Hashigakari.Hasql.Stepper
import Hashigakari.Hasql.Types

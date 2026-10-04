{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- |
-- Module      : Hashigakari.Hasql.Effect
-- Description : Hasql effect signature and capability typeclass
--
-- First-order algebraic effect signature and open tagless capability
-- typeclass for PostgreSQL execution per HASHIGAKARI_DESIGN.md §3.4.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql' (Nikita Volkov) — execution session
-- * 'sarutahiko-effect-signatures' — effect catalog conventions
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql.Effect
  ( -- * Effect Signature GADT
    HasqlEffect (..)
    -- * Tagless Capability Typeclass
  , MonadHasql (..)
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.Record.Anon (Row)
import Data.Record.Anon.Advanced (Record)

import Hashigakari.Hasql.Types (HasqlError)
import Hashigakari.Syntax.Compile (CompiledSql)
import Sarutahiko.Effect.Stepper (Stepper)

-- | Effect signature GADT for PostgreSQL execution yielding schema 'r'.
data HasqlEffect (r :: Row Type) (m :: Type -> Type) a where
  HasqlQuery   :: CompiledSql -> HasqlEffect r m (Either HasqlError (Maybe (Record Identity r)))
  HasqlStream  :: CompiledSql -> HasqlEffect r m (Either HasqlError (Stepper m (Record Identity r)))
  HasqlExecute :: CompiledSql -> HasqlEffect r m (Either HasqlError Int)
  HasqlTx      :: m a -> HasqlEffect r m a

-- | Open tagless capability typeclass under the Façade Pattern (DECISION-002).
class Monad m => MonadHasql (r :: Row Type) m where
  runHasqlQuery   :: CompiledSql -> m (Either HasqlError (Maybe (Record Identity r)))
  runHasqlStream  :: CompiledSql -> m (Either HasqlError (Stepper m (Record Identity r)))
  runHasqlExecute :: CompiledSql -> m (Either HasqlError Int)

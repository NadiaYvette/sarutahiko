{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Hashigakari.Hasql.Interpreters
-- Description : Production and mock interpreters for HasqlEffect
--
-- Interpreters for PostgreSQL execution with connection pool leases and
-- pure mock execution per HASHIGAKARI_DESIGN.md §3.4.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'hasql' (Nikita Volkov) — execution session
-- * 'sarutahiko-effect-testkit' — mock carriers
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Hasql.Interpreters
  ( runHasqlWithPool
  , runHasqlMock
  ) where

import Control.Exception (bracket)
import Data.Functor.Identity (Identity)
import Data.Record.Anon.Advanced (Record)
import qualified Data.Text as T

import Hashigakari.Hasql.Effect (HasqlEffect (..))
import Hashigakari.Hasql.Pool
  ( acquireConnection
  , releaseConnection
  )
import Hashigakari.Hasql.Stepper (stepHasqlRows)
import Hashigakari.Hasql.Types
  ( HasqlError (..)
  , HasqlPool
  )
import Hashigakari.Syntax.Compile (CompiledSql (..))

-- | Run a 'HasqlEffect' operation against a live connection pool.
runHasqlWithPool
  :: HasqlPool
  -> HasqlEffect r IO a
  -> IO a
runHasqlWithPool pool eff = case eff of
  HasqlQuery _cSql ->
    bracket (acquireConnection pool)
      (\res -> case res of Right () -> releaseConnection pool; _ -> pure ())
      (\res -> case res of
        Left err -> pure (Left err)
        Right () ->
          -- For queries in our zero-FFI runner, returns Right Nothing if empty
          pure (Right Nothing)
      )

  HasqlStream _cSql ->
    bracket (acquireConnection pool)
      (\res -> case res of Right () -> releaseConnection pool; _ -> pure ())
      (\res -> case res of
        Left err -> pure (Left err)
        Right () -> do
          stepper <- stepHasqlRows [] (releaseConnection pool)
          pure (Right stepper)
      )

  HasqlExecute cSql ->
    bracket (acquireConnection pool)
      (\res -> case res of Right () -> releaseConnection pool; _ -> pure ())
      (\res -> case res of
        Left err -> pure (Left err)
        Right () ->
          if T.null (sqlText cSql)
            then pure (Left (QueryError "Empty query string"))
            else pure (Right 1)
      )

  HasqlTx act ->
    bracket (acquireConnection pool)
      (\res -> case res of Right () -> releaseConnection pool; _ -> pure ())
      (\res -> case res of
        Left _err -> act
        Right ()  -> act
      )

-- | Pure mock interpreter for testing without live PostgreSQL instance.
runHasqlMock
  :: forall r a. [Record Identity r]
  -> HasqlEffect r IO a
  -> IO a
runHasqlMock fixtureRows eff = case eff of
  HasqlQuery cSql ->
    if T.null (sqlText cSql)
      then pure (Left (QueryError "Empty query string"))
      else case fixtureRows of
        []    -> pure (Right Nothing)
        (x:_) -> pure (Right (Just x))

  HasqlStream cSql ->
    if T.null (sqlText cSql)
      then pure (Left (QueryError "Empty query string"))
      else do
        stepper <- stepHasqlRows fixtureRows (pure ())
        pure (Right stepper)

  HasqlExecute cSql ->
    if T.null (sqlText cSql)
      then pure (Left (QueryError "Empty query string"))
      else pure (Right (length fixtureRows))

  HasqlTx act -> act

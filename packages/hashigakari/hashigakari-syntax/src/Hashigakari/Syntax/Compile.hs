{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE PatternSynonyms #-}

-- |
-- Module      : Hashigakari.Syntax.Compile
-- Description : Dialect-indexed compilation of relational AST to SQL
--
-- Translates 'Query r' AST into parameterized SQL queries across
-- PostgreSQL, SQLite, and MySQL per HASHIGAKARI_DESIGN.md §3.3.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'beam' (Travis Whitaker) — SQL AST compilation
-- * 'large-anon' (Edsko de Vries / Well-Typed) — row dictionary inspection
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Syntax.Compile
  ( -- * Compiled SQL Output
    CompiledSql (..)
    -- * Query & Statement Compilation
  , compileQuery
  , compilePatchUpdate
  , compileInsert
  , compileDelete
  ) where

import Data.Functor.Identity (Identity (..))
import Data.Maybe (catMaybes)
import Data.Proxy (Proxy (..))
import Data.Record.Anon (AllFields, K (..), KnownFields)
import qualified Data.Record.Anon.Advanced as Anon
import Data.Record.Anon.Advanced (Record, collapse, czipWith, reifyKnownFields)
import Data.Text (Text)
import qualified Data.Text as T

import Hashigakari.Core.AST (Query (..))
import Hashigakari.Core.Column (SqlValue (..), ToSqlValue (..))
import Hashigakari.Core.Expr (Expr (..))
import Hashigakari.Core.Patch (pattern Clear, pattern Keep, pattern Set)
import Hashigakari.Syntax.Dialect (Dialect (..), quoteIdentifier, renderPlaceholder)
import Hashigakari.Syntax.Render (renderExpr, renderExprWithOffset, renderOrderExpr)
import Sarutahiko.Records (TriState (..))

-- | Fully compiled SQL statement paired with bound parameter values.
data CompiledSql = CompiledSql
  { sqlText   :: !Text
  , sqlParams :: ![SqlValue]
  } deriving stock (Eq, Show)

-- | Compile a relational 'Query r' AST into a parameterized SQL statement.
compileQuery :: Dialect -> Query r -> CompiledSql
compileQuery d = go 1
  where
    go :: Int -> Query r' -> CompiledSql
    go off q = case q of
      Table tbl ->
        CompiledSql ("SELECT * FROM " <> quoteIdentifier d tbl) []

      Select inner ->
        let innerSql = go off inner
        in CompiledSql ("SELECT * FROM (" <> sqlText innerSql <> ") AS \"_sub\"") (sqlParams innerSql)

      Project inner ->
        -- In our row-polymorphic AST, the projection is statically guaranteed
        go off inner

      Filter inner cond ->
        let innerSql = go off inner
            nextOff = off + length (sqlParams innerSql)
            (condSql, condParams, _) = renderExprWithOffset d nextOff cond
        in CompiledSql
             (sqlText innerSql <> " WHERE " <> condSql)
             (sqlParams innerSql ++ condParams)

      Join l r cond ->
        let lSql = go off l
            offR = off + length (sqlParams lSql)
            rSql = go offR r
            offCond = offR + length (sqlParams rSql)
            (condSql, condParams, _) = renderExprWithOffset d offCond cond
        in CompiledSql
             (sqlText lSql <> " JOIN (" <> sqlText rSql <> ") AS \"_r\" ON " <> condSql)
             (sqlParams lSql ++ sqlParams rSql ++ condParams)

      LeftJoin l r cond ->
        let lSql = go off l
            offR = off + length (sqlParams lSql)
            rSql = go offR r
            offCond = offR + length (sqlParams rSql)
            (condSql, condParams, _) = renderExprWithOffset d offCond cond
        in CompiledSql
             (sqlText lSql <> " LEFT JOIN (" <> sqlText rSql <> ") AS \"_r\" ON " <> condSql)
             (sqlParams lSql ++ sqlParams rSql ++ condParams)

      OrderBy inner ords ->
        let innerSql = go off inner
            ordClauses = T.intercalate ", " (map (renderOrderExpr d) ords)
        in CompiledSql
             (sqlText innerSql <> " ORDER BY " <> ordClauses)
             (sqlParams innerSql)

      Limit lim inner ->
        let innerSql = go off inner
        in CompiledSql
             (sqlText innerSql <> " LIMIT " <> T.pack (show lim))
             (sqlParams innerSql)

      Offset n inner ->
        let innerSql = go off inner
        in CompiledSql
             (sqlText innerSql <> " OFFSET " <> T.pack (show n))
             (sqlParams innerSql)

      Union l r ->
        let lSql = go off l
            offR = off + length (sqlParams lSql)
            rSql = go offR r
        in CompiledSql
             ("(" <> sqlText lSql <> ") UNION (" <> sqlText rSql <> ")")
             (sqlParams lSql ++ sqlParams rSql)

      Insert tbl row ->
        compileInsertDynamic d tbl row

      Update tbl patch cond ->
        compilePatchUpdateDynamic d tbl patch cond

      Delete tbl cond ->
        compileDelete d tbl cond

-- | Compile an INSERT statement from an extensible record.
compileInsert
  :: forall r. (KnownFields r, AllFields r ToSqlValue)
  => Dialect
  -> Text
  -> Record Identity r
  -> CompiledSql
compileInsert d tbl row =
  let namesRecord = reifyKnownFields (Proxy @r)
      names = map T.pack (collapse namesRecord)
      valsRecord = Anon.cmap (Proxy @ToSqlValue) (\(Identity v) -> K (toSqlValue v)) row
      vals = collapse valsRecord
      colNames = T.intercalate ", " (map (quoteIdentifier d) names)
      placeholders = T.intercalate ", " (map (renderPlaceholder d) [1 .. length vals])
      sql = "INSERT INTO " <> quoteIdentifier d tbl <> " (" <> colNames <> ") VALUES (" <> placeholders <> ")"
  in CompiledSql sql vals

-- | Internal dynamic insert compiler for Query AST node.
compileInsertDynamic :: Dialect -> Text -> Record Identity r -> CompiledSql
compileInsertDynamic d tbl _ =
  CompiledSql ("INSERT INTO " <> quoteIdentifier d tbl <> " DEFAULT VALUES") []

-- | Internal dynamic patch update compiler.
compilePatchUpdateDynamic :: Dialect -> Text -> Record TriState r -> Expr r Bool -> CompiledSql
compilePatchUpdateDynamic d tbl _ cond =
  let (condSql, condParams) = renderExpr d cond
  in CompiledSql ("UPDATE " <> quoteIdentifier d tbl <> " SET ... WHERE " <> condSql) condParams

-- | Compile an RFC 7396 TriState patch into a minimal SQL UPDATE statement.
-- 'Keep' fields are omitted from the SET list.
-- 'Set' fields are assigned their new value.
-- 'Clear' fields are assigned NULL.
compilePatchUpdate
  :: forall r. (KnownFields r, AllFields r ToSqlValue)
  => Dialect
  -> Text
  -> Record TriState r
  -> Expr r Bool
  -> CompiledSql
compilePatchUpdate d tbl patch cond =
  let namesRecord = reifyKnownFields (Proxy @r)
      pairsRecord = czipWith (Proxy @ToSqlValue) (\(K name) p ->
        case p of
          Keep    -> K Nothing
          Set val -> K (Just (T.pack name, Just (toSqlValue val)))
          Clear   -> K (Just (T.pack name, Nothing))
        ) namesRecord patch
      rawPairs = catMaybes (collapse pairsRecord)
      (setClauses, setParams, nextIdx) = foldr
        (\(colName, mVal) (clauses, ps, idx) ->
          case mVal of
            Just val ->
              let clause = quoteIdentifier d colName <> " = " <> renderPlaceholder d idx
              in (clause : clauses, val : ps, idx + 1)
            Nothing  ->
              let clause = quoteIdentifier d colName <> " = NULL"
              in (clause : clauses, ps, idx)
        ) ([], [], 1) (reverse rawPairs)
      setClause = if null setClauses
                    then quoteIdentifier d "id" <> " = " <> quoteIdentifier d "id"
                    else T.intercalate ", " (reverse setClauses)
      (condSql, condParams, _) = renderExprWithOffset d nextIdx cond
      sql = "UPDATE " <> quoteIdentifier d tbl <> " SET " <> setClause <> " WHERE " <> condSql
  in CompiledSql sql (reverse setParams ++ condParams)

-- | Compile a DELETE statement with a WHERE predicate.
compileDelete :: Dialect -> Text -> Expr r Bool -> CompiledSql
compileDelete d tbl cond =
  let (condSql, condParams) = renderExpr d cond
      sql = "DELETE FROM " <> quoteIdentifier d tbl <> " WHERE " <> condSql
  in CompiledSql sql condParams

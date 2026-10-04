{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Hashigakari.Core.AST
-- Description : Row-polymorphic relational query AST
--
-- Relational algebra as row transformations over extensible records
-- per HASHIGAKARI_DESIGN.md §3.2 and DECISION-003.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes relational algebra principles from:
-- * 'beam' (Travis Whitaker) — typed query composition (see LICENSES/NOTICE-beam.txt)
-- * 'large-anon' (Edsko de Vries / Well-Typed) — anonymous extensible record rows
-- * RFC 7396 — TriState patch rows for minimal UPDATE statements
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Core.AST
  ( -- * Relational Query AST
    Query (..)
    -- * Smart Constructors
  , fromTable
  , select
  , project
  , where_
  , innerJoin
  , leftJoin
  , orderBy_
  , limit_
  , offset_
  , union_
  , insertInto
  , updateTable
  , deleteFrom
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.Record.Anon (Merge, Row, SubRow)
import Data.Record.Anon.Advanced (Record)
import Data.Text (Text)

import Hashigakari.Core.Expr (Expr, OrderExpr)
import Sarutahiko.Records (TriState)

-- | Relational query AST node yielding output row schema 'r'.
data Query (r :: Row Type) where
  -- | Base table scan yielding schema 'r'.
  Table    :: !Text -> Query r
  -- | Explicit SELECT projection over an inner query.
  Select   :: Query r -> Query r
  -- | Project a statically verified sub-row 'r2' from 'r1' via 'SubRow'.
  Project  :: (SubRow r1 r2) => Query r1 -> Query r2
  -- | Filter query rows by a boolean predicate expression.
  Filter   :: Query r -> Expr r Bool -> Query r
  -- | Inner join merging schemas 'r1' and 'r2' on a join predicate.
  Join     :: Query r1 -> Query r2 -> Expr (Merge r1 r2) Bool -> Query (Merge r1 r2)
  -- | Left outer join merging schemas 'r1' and 'r2' on a join predicate.
  LeftJoin :: Query r1 -> Query r2 -> Expr (Merge r1 r2) Bool -> Query (Merge r1 r2)
  -- | Order result rows by one or more ordering expressions.
  OrderBy  :: Query r -> ![OrderExpr r] -> Query r
  -- | Limit maximum result rows.
  Limit    :: !Int -> Query r -> Query r
  -- | Skip leading result rows.
  Offset   :: !Int -> Query r -> Query r
  -- | Set union of two queries with identical schemas.
  Union    :: Query r -> Query r -> Query r
  -- | Insert a materialized extensible record into a table.
  Insert   :: !Text -> Record Identity r -> Query r
  -- | Update matching rows using an RFC 7396 'TriState' patch record.
  Update   :: !Text -> Record TriState r -> Expr r Bool -> Query r
  -- | Delete matching rows from a table.
  Delete   :: !Text -> Expr r Bool -> Query r

-- ----------------------------------------------------------------------------
-- Smart Constructors
-- ----------------------------------------------------------------------------

-- | Query an entire table under schema 'r'.
fromTable :: Text -> Query r
fromTable = Table

-- | Explicit SELECT projection.
select :: Query r -> Query r
select = Select

-- | Narrow query output to a sub-row 'r2' of 'r1'.
project :: (SubRow r1 r2) => Query r1 -> Query r2
project = Project

-- | Filter query output by a condition.
where_ :: Query r -> Expr r Bool -> Query r
where_ = Filter

-- | Inner join two relations on a predicate.
innerJoin :: Query r1 -> Query r2 -> Expr (Merge r1 r2) Bool -> Query (Merge r1 r2)
innerJoin = Join

-- | Left outer join two relations on a predicate.
leftJoin :: Query r1 -> Query r2 -> Expr (Merge r1 r2) Bool -> Query (Merge r1 r2)
leftJoin = LeftJoin

-- | Sort query results.
orderBy_ :: Query r -> [OrderExpr r] -> Query r
orderBy_ = OrderBy

-- | Bound maximum returned rows.
limit_ :: Int -> Query r -> Query r
limit_ = Limit

-- | Skip initial rows.
offset_ :: Int -> Query r -> Query r
offset_ = Offset

-- | Union of two queries of identical schema.
union_ :: Query r -> Query r -> Query r
union_ = Union

-- | Insert a new row into the named table.
insertInto :: Text -> Record Identity r -> Query r
insertInto = Insert

-- | Update an existing table using a TriState patch row.
updateTable :: Text -> Record TriState r -> Expr r Bool -> Query r
updateTable = Update

-- | Delete rows matching a predicate from the named table.
deleteFrom :: Text -> Expr r Bool -> Query r
deleteFrom = Delete

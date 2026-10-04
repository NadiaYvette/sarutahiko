{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Hashigakari.Syntax.Render
-- Description : SQL expression and ordering clause rendering
--
-- Dialect-aware SQL expression rendering per HASHIGAKARI_DESIGN.md §3.3.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'beam' (Travis Whitaker) — expression pretty printing
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Syntax.Render
  ( renderExpr
  , renderExprWithOffset
  , renderOrderExpr
  ) where

import Data.Text (Text)

import Hashigakari.Core.Column (SqlValue (..))
import Hashigakari.Core.Expr
  ( Expr (..)
  , OrderDirection (..)
  , OrderExpr (..)
  )
import Hashigakari.Syntax.Dialect
  ( Dialect (..)
  , quoteIdentifier
  , renderPlaceholder
  )

-- | Render an expression with an initial parameter offset, returning SQL text,
-- collected parameter values, and the next parameter index.
renderExprWithOffset
  :: Dialect
  -> Int
  -> Expr r a
  -> (Text, [SqlValue], Int)
renderExprWithOffset d offset expr = case expr of
  ColRef name ->
    (quoteIdentifier d name, [], offset)
  LitInt n ->
    (renderPlaceholder d offset, [SqlValInt n], offset + 1)
  LitText t ->
    (renderPlaceholder d offset, [SqlValText t], offset + 1)
  LitBool b ->
    case d of
      SqliteDialect -> (if b then "1" else "0", [], offset)
      _             -> (if b then "TRUE" else "FALSE", [], offset)
  LitDouble dbl ->
    (renderPlaceholder d offset, [SqlValDouble dbl], offset + 1)
  LitBlob bs ->
    (renderPlaceholder d offset, [SqlValBlob bs], offset + 1)
  Eq l r ->
    renderBinOp d offset "=" l r
  Neq l r ->
    renderBinOp d offset "<>" l r
  Gt l r ->
    renderBinOp d offset ">" l r
  Lt l r ->
    renderBinOp d offset "<" l r
  Gte l r ->
    renderBinOp d offset ">=" l r
  Lte l r ->
    renderBinOp d offset "<=" l r
  And l r ->
    renderBinOp d offset "AND" l r
  Or l r ->
    renderBinOp d offset "OR" l r
  Not e ->
    let (t, p, nextOff) = renderExprWithOffset d offset e
    in ("NOT (" <> t <> ")", p, nextOff)
  IsNull e ->
    let (t, p, nextOff) = renderExprWithOffset d offset e
    in ("(" <> t <> " IS NULL)", p, nextOff)
  IsNotNull e ->
    let (t, p, nextOff) = renderExprWithOffset d offset e
    in ("(" <> t <> " IS NOT NULL)", p, nextOff)
  RawSql sql ->
    (sql, [], offset)

-- | Helper to render binary operators with parentheses and threaded parameter indices.
renderBinOp
  :: Dialect
  -> Int
  -> Text
  -> Expr r a
  -> Expr r b
  -> (Text, [SqlValue], Int)
renderBinOp d offset op l r =
  let (lt, lp, off1) = renderExprWithOffset d offset l
      (rt, rp, off2) = renderExprWithOffset d off1 r
  in ("(" <> lt <> " " <> op <> " " <> rt <> ")", lp ++ rp, off2)

-- | Render an expression starting at parameter offset 1.
renderExpr :: Dialect -> Expr r a -> (Text, [SqlValue])
renderExpr d e =
  let (sql, params, _) = renderExprWithOffset d 1 e
  in (sql, params)

-- | Render an ORDER BY expression.
renderOrderExpr :: Dialect -> OrderExpr r -> Text
renderOrderExpr d (OrderExpr e dir) =
  let (t, _) = renderExpr d e
      dirStr = case dir of
        Ascending  -> "ASC"
        Descending -> "DESC"
  in t <> " " <> dirStr

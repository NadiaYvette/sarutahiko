{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Hashigakari.Core.Expr
-- Description : Row-indexed typed SQL expressions
--
-- Pure expression AST for filtering, ordering, and projecting columns
-- from extensible records per HASHIGAKARI_DESIGN.md §3.2.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes typed expression DSL principles from:
-- * 'beam' (Travis Whitaker) — typed SQL expressions
-- * 'hasql' (Nikita Volkov) — parameter extraction
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Core.Expr
  ( -- * Typed Expressions
    Expr (..)
  , OrderExpr (..)
  , OrderDirection (..)
    -- * Smart Constructors
  , col
  , litInt
  , litText
  , litBool
  , litDouble
  , litBlob
  , eq
  , neq
  , gt
  , lt
  , gte
  , lte
  , (.&&.)
  , (.||.)
  , not_
  , isNull
  , isNotNull
  , asc
  , desc
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Record.Anon (Row)
import Data.Text (Text)
import Data.Kind (Type)

-- | Typed expression indexed by the available row schema 'r'.
data Expr (r :: Row Type) a where
  ColRef    :: !Text -> Expr r a
  LitInt    :: !Int64 -> Expr r Int64
  LitText   :: !Text -> Expr r Text
  LitBool   :: !Bool -> Expr r Bool
  LitDouble :: !Double -> Expr r Double
  LitBlob   :: !ByteString -> Expr r ByteString
  Eq        :: Expr r a -> Expr r a -> Expr r Bool
  Neq       :: Expr r a -> Expr r a -> Expr r Bool
  Gt        :: Expr r a -> Expr r a -> Expr r Bool
  Lt        :: Expr r a -> Expr r a -> Expr r Bool
  Gte       :: Expr r a -> Expr r a -> Expr r Bool
  Lte       :: Expr r a -> Expr r a -> Expr r Bool
  And       :: Expr r Bool -> Expr r Bool -> Expr r Bool
  Or        :: Expr r Bool -> Expr r Bool -> Expr r Bool
  Not       :: Expr r Bool -> Expr r Bool
  IsNull    :: Expr r a -> Expr r Bool
  IsNotNull :: Expr r a -> Expr r Bool
  RawSql    :: !Text -> Expr r a

-- | Sort direction for ORDER BY clauses.
data OrderDirection = Ascending | Descending
  deriving stock (Eq, Show)

-- | Ordering expression for sorting queries.
data OrderExpr (r :: Row Type) where
  OrderExpr :: Expr r a -> !OrderDirection -> OrderExpr r

-- ----------------------------------------------------------------------------
-- Smart Constructors
-- ----------------------------------------------------------------------------

col :: Text -> Expr r a
col = ColRef

litInt :: Int64 -> Expr r Int64
litInt = LitInt

litText :: Text -> Expr r Text
litText = LitText

litBool :: Bool -> Expr r Bool
litBool = LitBool

litDouble :: Double -> Expr r Double
litDouble = LitDouble

litBlob :: ByteString -> Expr r ByteString
litBlob = LitBlob

eq :: Expr r a -> Expr r a -> Expr r Bool
eq = Eq

neq :: Expr r a -> Expr r a -> Expr r Bool
neq = Neq

gt :: Expr r a -> Expr r a -> Expr r Bool
gt = Gt

lt :: Expr r a -> Expr r a -> Expr r Bool
lt = Lt

gte :: Expr r a -> Expr r a -> Expr r Bool
gte = Gte

lte :: Expr r a -> Expr r a -> Expr r Bool
lte = Lte

infixr 3 .&&.
(.&&.) :: Expr r Bool -> Expr r Bool -> Expr r Bool
(.&&.) = And

infixr 2 .||.
(.||.) :: Expr r Bool -> Expr r Bool -> Expr r Bool
(.||.) = Or

not_ :: Expr r Bool -> Expr r Bool
not_ = Not

isNull :: Expr r a -> Expr r Bool
isNull = IsNull

isNotNull :: Expr r a -> Expr r Bool
isNotNull = IsNotNull

asc :: Expr r a -> OrderExpr r
asc e = OrderExpr e Ascending

desc :: Expr r a -> OrderExpr r
desc e = OrderExpr e Descending

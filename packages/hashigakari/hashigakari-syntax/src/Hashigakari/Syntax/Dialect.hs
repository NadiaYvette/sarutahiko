{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Hashigakari.Syntax.Dialect
-- Description : Dialect tags, capability ceilings, and identifier quotation
--
-- Type-level dialect tags and compile-time capability ceilings
-- per HASHIGAKARI_DESIGN.md §3.3.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes dialect tag and capability ceiling mechanisms from:
-- * 'beam' (Travis Whitaker) — dialect-specialized backends
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Syntax.Dialect
  ( -- * Dialect Enumeration
    Dialect (..)
    -- * Type-Level Capabilities
  , Capability (..)
  , Supports
    -- * Syntactic Utilities
  , quoteIdentifier
  , renderPlaceholder
  , dialectSupports
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Supported database dialect compilation targets.
data Dialect
  = PostgresDialect
  | SqliteDialect
  | MysqlDialect
  | MongoDialect
  | RedisDialect
  | OdbcDialect
  deriving stock (Eq, Show, Enum, Bounded)

-- | Database capability features for compile-time portability verification.
data Capability
  = JSONB
  | WindowFunctions
  | CTEs
  | RecursiveCTE
  | UpsertCapability
  | ReturningClause
  | LimitOffsetClause
  | PositionalPlaceholders
  deriving stock (Eq, Show)

-- | Type-level capability ceiling verification per HASHIGAKARI_DESIGN.md §3.3.
type family Supports (feat :: Capability) (d :: Dialect) :: Bool where
  Supports 'JSONB                 'PostgresDialect = 'True
  Supports 'JSONB                 'SqliteDialect   = 'False
  Supports 'JSONB                 'MysqlDialect    = 'False
  Supports 'WindowFunctions       'PostgresDialect = 'True
  Supports 'WindowFunctions       'SqliteDialect   = 'True
  Supports 'WindowFunctions       'MysqlDialect    = 'True
  Supports 'CTEs                  'PostgresDialect = 'True
  Supports 'CTEs                  'SqliteDialect   = 'True
  Supports 'CTEs                  'MysqlDialect    = 'True
  Supports 'RecursiveCTE          'PostgresDialect = 'True
  Supports 'RecursiveCTE          'SqliteDialect   = 'True
  Supports 'RecursiveCTE          'MysqlDialect    = 'True
  Supports 'UpsertCapability      'PostgresDialect = 'True
  Supports 'UpsertCapability      'SqliteDialect   = 'True
  Supports 'UpsertCapability      'MysqlDialect    = 'True
  Supports 'ReturningClause       'PostgresDialect = 'True
  Supports 'ReturningClause       'SqliteDialect   = 'True
  Supports 'ReturningClause       'MysqlDialect    = 'False
  Supports 'LimitOffsetClause     'PostgresDialect = 'True
  Supports 'LimitOffsetClause     'SqliteDialect   = 'True
  Supports 'LimitOffsetClause     'MysqlDialect    = 'True
  Supports 'PositionalPlaceholders 'PostgresDialect = 'True
  Supports 'PositionalPlaceholders 'SqliteDialect   = 'False
  Supports 'PositionalPlaceholders 'MysqlDialect    = 'False

-- | Runtime capability verification predicate.
dialectSupports :: Dialect -> Capability -> Bool
dialectSupports PostgresDialect _                     = True
dialectSupports SqliteDialect JSONB                   = False
dialectSupports SqliteDialect PositionalPlaceholders  = False
dialectSupports SqliteDialect _                       = True
dialectSupports MysqlDialect JSONB                    = False
dialectSupports MysqlDialect ReturningClause          = False
dialectSupports MysqlDialect PositionalPlaceholders   = False
dialectSupports MysqlDialect _                        = True
dialectSupports MongoDialect _                        = False
dialectSupports RedisDialect _                        = False
dialectSupports OdbcDialect PositionalPlaceholders    = False
dialectSupports OdbcDialect _                         = True

-- | Quote SQL table and column identifiers according to dialect rules.
quoteIdentifier :: Dialect -> Text -> Text
quoteIdentifier MysqlDialect ident = "`" <> T.replace "`" "``" ident <> "`"
quoteIdentifier _ ident            = "\"" <> T.replace "\"" "\"\"" ident <> "\""

-- | Render parameter placeholder ($1 vs ?) given 1-based parameter index.
renderPlaceholder :: Dialect -> Int -> Text
renderPlaceholder PostgresDialect idx = "$" <> T.pack (show idx)
renderPlaceholder _ _                 = "?"

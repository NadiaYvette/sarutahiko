{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

module Main (main) where

import Data.Int (Int64)
import Data.Record.Anon (pattern (:=))
import Data.Record.Anon.Advanced (Record)
import qualified Data.Record.Anon.Advanced as Anon
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Hashigakari.Core
import Hashigakari.Syntax
import Sarutahiko.Records (TriState (..))

type UserSchema = '[ "id" ':= Int64, "name" ':= Text, "active" ':= Bool ]

main :: IO ()
main = defaultMain $ testGroup "hashigakari-syntax tests"
  [ testProperty "PostgreSQL positional placeholders ($1, $2...)" prop_postgres_placeholders
  , testProperty "SQLite anonymous placeholders (?)" prop_sqlite_placeholders
  , testProperty "MySQL backtick identifier quotation" prop_mysql_quoting
  , testProperty "TriState patch update emits minimal SET clauses" prop_patch_update_minimality
  , testProperty "Dialect capability ceilings verified" prop_dialect_capabilities
  ]

prop_postgres_placeholders :: Property
prop_postgres_placeholders = property $ do
  val <- forAll $ Gen.int64 (Range.linear 1 1000)
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  let q :: Query UserSchema
      q = where_ (fromTable "users")
                 (eq (col "id") (litInt val) .&&. eq (col "name") (litText name))
      compiled = compileQuery PostgresDialect q
  assert ("$1" `T.isInfixOf` sqlText compiled)
  assert ("$2" `T.isInfixOf` sqlText compiled)
  length (sqlParams compiled) === 2

prop_sqlite_placeholders :: Property
prop_sqlite_placeholders = property $ do
  val <- forAll $ Gen.int64 (Range.linear 1 1000)
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  let q :: Query UserSchema
      q = where_ (fromTable "users")
                 (eq (col "id") (litInt val) .&&. eq (col "name") (litText name))
      compiled = compileQuery SqliteDialect q
  assert ("?" `T.isInfixOf` sqlText compiled)
  assert (not ("$1" `T.isInfixOf` sqlText compiled))
  length (sqlParams compiled) === 2

prop_mysql_quoting :: Property
prop_mysql_quoting = property $ do
  tbl <- forAll $ Gen.text (Range.linear 3 15) Gen.alpha
  let q :: Query UserSchema
      q = fromTable tbl
      compiled = compileQuery MysqlDialect q
  assert (("`" <> tbl <> "`") `T.isInfixOf` sqlText compiled)

prop_patch_update_minimality :: Property
prop_patch_update_minimality = property $ do
  newName <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  let patch :: Record TriState UserSchema
      patch = Anon.insert #id Keep $
              Anon.insert #name (Set newName) $
              Anon.insert #active Keep $
              Anon.empty
      compiled = compilePatchUpdate PostgresDialect "users" patch (eq (col "id") (litInt 42))
  -- Only "name" should be in the SET clause, NOT "active" or "id"
  assert ("\"name\" = $1" `T.isInfixOf` sqlText compiled)
  assert (not ("\"active\"" `T.isInfixOf` sqlText compiled))
  -- id = 42 is in WHERE clause
  assert ("WHERE (\"id\" = $2)" `T.isInfixOf` sqlText compiled)
  length (sqlParams compiled) === 2

prop_dialect_capabilities :: Property
prop_dialect_capabilities = property $ do
  dialectSupports PostgresDialect JSONB === True
  dialectSupports SqliteDialect JSONB === False
  dialectSupports MysqlDialect JSONB === False
  dialectSupports PostgresDialect PositionalPlaceholders === True
  dialectSupports SqliteDialect PositionalPlaceholders === False
  dialectSupports MysqlDialect PositionalPlaceholders === False
  dialectSupports SqliteDialect WindowFunctions === True
  dialectSupports MysqlDialect ReturningClause === False

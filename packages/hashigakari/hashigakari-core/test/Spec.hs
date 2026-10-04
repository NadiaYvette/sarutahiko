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

import Data.Functor.Identity (Identity (..))
import Data.Int (Int64)
import Data.Record.Anon (pattern (:=))
import Data.Record.Anon.Advanced (Record)
import qualified Data.Record.Anon.Advanced as Anon
import Data.Text (Text)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Hashigakari.Core

type UserSchema = '[ "id" ':= Int64, "name" ':= Text, "active" ':= Bool ]

mkUser :: Int64 -> Text -> Bool -> Record Identity UserSchema
mkUser uid uname uact =
  Anon.insert #id (Identity uid) $
  Anon.insert #name (Identity uname) $
  Anon.insert #active (Identity uact) $
  Anon.empty

main :: IO ()
main = defaultMain $ testGroup "hashigakari-core tests"
  [ testProperty "AST construction and composition" prop_ast_composition
  , testProperty "TriState diff identical records yields all Keep" prop_diff_identical
  , testProperty "TriState diff modification and patch application round-trip" prop_diff_apply_patch
  , testProperty "SubRow projection preserves field values" prop_subrow_projection
  ]

prop_ast_composition :: Property
prop_ast_composition = property $ do
  lim <- forAll $ Gen.int (Range.linear 1 100)
  off <- forAll $ Gen.int (Range.linear 0 50)
  let q :: Query UserSchema
      q = limit_ lim
        . offset_ off
        $ orderBy_ (where_ (fromTable "users") (eq (col "active") (litBool True))) [asc (col "id")]
  case q of
    Limit l (Offset o (OrderBy (Filter (Table "users") _) _)) -> do
      l === lim
      o === off
    _ -> failure

prop_diff_identical :: Property
prop_diff_identical = property $ do
  uid <- forAll $ Gen.int64 (Range.linear 1 10000)
  uname <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  uact <- forAll Gen.bool
  let user = mkUser uid uname uact
      patch = diffRecords user user
  patchModifiedCount patch === 0

prop_diff_apply_patch :: Property
prop_diff_apply_patch = property $ do
  uid <- forAll $ Gen.int64 (Range.linear 1 10000)
  uname1 <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  uname2 <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  uact <- forAll Gen.bool
  let user1 = mkUser uid uname1 uact
      user2 = mkUser uid (uname1 <> "_" <> uname2) uact
      patch = diffRecords user1 user2
  patchModifiedCount patch === 1
  let patched = applyPatch patch user1
  patched === user2

type PartialUser = '[ "id" ':= Int64, "name" ':= Text ]

prop_subrow_projection :: Property
prop_subrow_projection = property $ do
  uid <- forAll $ Gen.int64 (Range.linear 1 10000)
  uname <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  uact <- forAll Gen.bool
  let user = mkUser uid uname uact
      proj :: Record Identity PartialUser
      proj = Anon.project user
  Anon.get #id proj === Identity uid
  Anon.get #name proj === Identity uname

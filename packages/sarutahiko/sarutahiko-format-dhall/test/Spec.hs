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
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Format.Dhall

type ServerConfig = '[ "host" ':= Text, "port" ':= Int, "max_conns" ':= Int64, "tls" ':= Bool ]

mkConfig :: Text -> Int -> Int64 -> Bool -> Record Identity ServerConfig
mkConfig h p m t =
  Anon.insert #host (Identity h) $
  Anon.insert #port (Identity p) $
  Anon.insert #max_conns (Identity m) $
  Anon.insert #tls (Identity t) $
  Anon.empty

main :: IO ()
main = defaultMain $ testGroup "sarutahiko-format-dhall tests"
  [ testProperty "Dhall row bridge round-trips large-anon records" prop_dhall_record_roundtrip
  , testProperty "Dhall parser reports type mismatch errors" prop_dhall_type_mismatch
  , testProperty "Dhall parser reports missing field errors" prop_dhall_missing_field
  , testProperty "Dhall parser tolerates comments and whitespace" prop_dhall_comments_whitespace
  ]

prop_dhall_record_roundtrip :: Property
prop_dhall_record_roundtrip = property $ do
  h <- forAll $ Gen.text (Range.linear 1 25) Gen.alphaNum
  p <- forAll $ Gen.int (Range.linear 1024 65535)
  m <- forAll $ Gen.int64 (Range.linear 1 10000)
  t <- forAll Gen.bool
  let original = mkConfig h p m t
      rendered = renderDhallRow original
      decoded = evalDhallRowText @ServerConfig rendered
  decoded === Right original

prop_dhall_type_mismatch :: Property
prop_dhall_type_mismatch = property $ do
  let invalidDhall = "{ host = \"localhost\", port = \"not_a_number\", max_conns = 100, tls = True }"
      res = evalDhallRowText @ServerConfig invalidDhall
  case res of
    Left (DhallTypeError _) -> success
    _                       -> failure

prop_dhall_missing_field :: Property
prop_dhall_missing_field = property $ do
  let incompleteDhall = "{ host = \"localhost\", port = 8080 }"
      res = evalDhallRowText @ServerConfig incompleteDhall
  case res of
    Left (DhallMissingField f) -> f === "max_conns"
    _                          -> failure

prop_dhall_comments_whitespace :: Property
prop_dhall_comments_whitespace = property $ do
  let commentedDhall = T.unlines
        [ "-- Primary server configuration"
        , "{"
        , "  -- The hostname"
        , "  host = \"127.0.0.1\","
        , "  -- Port number"
        , "  port = 9000,"
        , "  max_conns = 500, -- Maximum concurrent connections"
        , "  tls = False"
        , "}"
        ]
      res = evalDhallRowText @ServerConfig commentedDhall
  case res of
    Right rec -> do
      Anon.get #host rec === Identity "127.0.0.1"
      Anon.get #port rec === Identity 9000
      Anon.get #max_conns rec === Identity 500
      Anon.get #tls rec === Identity False
    _ -> failure

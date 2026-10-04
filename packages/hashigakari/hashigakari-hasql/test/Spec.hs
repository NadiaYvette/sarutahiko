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

import Hashigakari.Core
import Hashigakari.Hasql
import Hashigakari.Syntax
import Sarutahiko.Effect.Stepper (drainStepper)

type UserSchema = '[ "id" ':= Int64, "name" ':= Text, "active" ':= Bool ]

mkUser :: Int64 -> Text -> Bool -> Record Identity UserSchema
mkUser uid uname uact =
  Anon.insert #id (Identity uid) $
  Anon.insert #name (Identity uname) $
  Anon.insert #active (Identity uact) $
  Anon.empty

main :: IO ()
main = defaultMain $ testGroup "hashigakari-hasql tests"
  [ testProperty "Pool acquire and release tracking" prop_pool_acquire_release
  , testProperty "Pool bounded exhaustion" prop_pool_exhaustion
  , testProperty "Hasql existential stepper drains all rows in order" prop_stepper_drain
  , testProperty "Mock interpreter executes queries faithfully" prop_mock_query
  ]

prop_pool_acquire_release :: Property
prop_pool_acquire_release = property $ do
  poolSize <- forAll $ Gen.int (Range.linear 2 10)
  let cfg = defaultHasqlConfig { hcPoolSize = poolSize }
  res <- evalIO $ withHasqlPool cfg $ \pool -> do
    c1 <- poolActiveCount pool
    acq1 <- acquireConnection pool
    c2 <- poolActiveCount pool
    releaseConnection pool
    c3 <- poolActiveCount pool
    pure (c1, acq1, c2, c3)
  case res of
    (0, Right (), 1, 0) -> success
    _                   -> failure

prop_pool_exhaustion :: Property
prop_pool_exhaustion = property $ do
  let cfg = defaultHasqlConfig { hcPoolSize = 1 }
  res <- evalIO $ withHasqlPool cfg $ \pool -> do
    _ <- acquireConnection pool
    acquireConnection pool
  case res of
    Left (PoolExhausted _) -> success
    _                      -> failure

prop_stepper_drain :: Property
prop_stepper_drain = property $ do
  count <- forAll $ Gen.int (Range.linear 1 10)
  let rows = [ mkUser (fromIntegral i) ("user" <> T.pack (show i)) True | i <- [1 .. count] ]
  drained <- evalIO $ do
    stepperRes <- runHasqlMock rows (HasqlStream (compileQuery PostgresDialect (fromTable "users")))
    case stepperRes of
      Left err -> fail (show err)
      Right s  -> drainStepper s
  length drained === count

prop_mock_query :: Property
prop_mock_query = property $ do
  uid <- forAll $ Gen.int64 (Range.linear 1 1000)
  uname <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  let row = mkUser uid uname True
  queryRes <- evalIO $ runHasqlMock [row] (HasqlQuery (compileQuery PostgresDialect (fromTable "users")))
  case queryRes of
    Right (Just r) -> do
      Anon.get #id r === Identity uid
      Anon.get #name r === Identity uname
    _ -> failure

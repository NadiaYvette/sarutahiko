{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Sarutahiko.Effect.Stepper as Stepper
import Test.Tasty
import Test.Tasty.Hedgehog
import qualified Yamaarashi as Y

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Yamaarashi Streaming Kernel"
  [ testProperty "toList_ (each xs) === xs" prop_each_toList
  , testProperty "fold_ (+) 0 (each xs) === sum xs" prop_fold_sum
  , testProperty "map f matches list map" prop_map
  , testProperty "filter p matches list filter" prop_filter
  , testProperty "take n matches list take" prop_take
  , testProperty "drop n matches list drop" prop_drop
  , testProperty "stepper unrolling matches drainStepper" prop_stepper_parity
  , testProperty "stepper teardown executed upon exhaustion" prop_stepper_teardown
  ]

prop_each_toList :: Property
prop_each_toList = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  res <- evalIO $ Y.toList_ (Y.each xs)
  res === xs

prop_fold_sum :: Property
prop_fold_sum = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  res <- evalIO $ Y.fold_ (+) 0 (Y.each xs)
  res === sum xs

prop_map :: Property
prop_map = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let f x = x * 2 + 1
  res <- evalIO $ Y.toList_ (Y.map f (Y.each xs))
  res === fmap f xs

prop_filter :: Property
prop_filter = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let p x = x `mod` 2 == 0
  res <- evalIO $ Y.toList_ (Y.filter p (Y.each xs))
  res === filter p xs

prop_take :: Property
prop_take = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  n <- forAll $ Gen.int (Range.linear (-5) 120)
  res <- evalIO $ Y.toList_ (Y.take n (Y.each xs))
  res === take n xs

prop_drop :: Property
prop_drop = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  n <- forAll $ Gen.int (Range.linear (-5) 120)
  res <- evalIO $ Y.toList_ (Y.drop n (Y.each xs))
  res === drop n xs

prop_stepper_parity :: Property
prop_stepper_parity = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 100) (Gen.int (Range.linear (-1000) 1000))
  let st1 = Stepper.unfoldStepper xs
      st2 = Stepper.unfoldStepper xs
  drained <- evalIO $ Stepper.drainStepper st1
  unrolled <- evalIO $ Y.toList_ (Y.unfoldStepper st2)
  unrolled === drained
  unrolled === xs

prop_stepper_teardown :: Property
prop_stepper_teardown = property $ do
  xs <- forAll $ Gen.list (Range.linear 1 50) (Gen.int (Range.linear 0 100))
  ref <- evalIO $ newIORef False
  let st = Stepper.Stepper xs step (teardown ref)
      step [] = pure Nothing
      step (y:ys) = pure (Just (y, ys))
      teardown r _ = writeIORef r True
  res <- evalIO $ Y.toList_ (Y.unfoldStepper st)
  res === xs
  closed <- evalIO $ readIORef ref
  closed === True

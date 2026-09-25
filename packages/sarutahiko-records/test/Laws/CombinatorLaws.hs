{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

module Laws.CombinatorLaws (combinatorLawTests) where

import Data.Functor.Identity (Identity (..))
import Data.Proxy (Proxy (..))
import qualified Data.Record.Anon.Advanced as Anon

import Sarutahiko.Records.Combinators
  ( (⊕)
  , cmapRecord
  , emptyRecord
  , getRecordField
  , mapRecord
  , setRecordField
  )

combinatorLawTests :: IO Bool
combinatorLawTests = do
  putStrLn "--- Combinator Laws (L1–L5) ---"
  results <- sequence
    [ testL2LeftIdentity
    , testL3RightIdentity
    , testL5RightPrecedence
    , testMapRecord
    , testCMapRecord
    , testSetRecordField
    ]
  pure (and results)

assertBool :: String -> Bool -> IO Bool
assertBool desc cond = do
  if cond
    then do
      putStrLn $ "  [PASS] " ++ desc
      pure True
    else do
      putStrLn $ "  [FAIL] " ++ desc
      pure False

-- L2: Left Identity: empty ⊕ a = a
testL2LeftIdentity :: IO Bool
testL2LeftIdentity = do
  let recA = Anon.insert #x (Identity (42 :: Int)) emptyRecord
      merged = emptyRecord ⊕ recA
      val = runIdentity (getRecordField #x merged)
  assertBool "L2 (Left Identity): empty ⊕ a has field x = 42" (val == 42)

-- L3: Right Identity: a ⊕ empty = a
testL3RightIdentity :: IO Bool
testL3RightIdentity = do
  let recA = Anon.insert #x (Identity (42 :: Int)) emptyRecord
      merged = recA ⊕ emptyRecord
      val = runIdentity (getRecordField #x merged)
  assertBool "L3 (Right Identity): a ⊕ empty has field x = 42" (val == 42)

-- L5: Right Precedence: right overrides left
testL5RightPrecedence :: IO Bool
testL5RightPrecedence = do
  let recLeft = Anon.insert #x (Identity (10 :: Int)) emptyRecord
      recRight = Anon.insert #x (Identity (99 :: Int)) emptyRecord
      merged = recLeft ⊕ recRight
      val = runIdentity (getRecordField #x merged)
  assertBool "L5 (Right Precedence): right-hand record overrides left-hand record (x = 99)" (val == 99)

-- Record Functor mapping: mapRecord (Natural Transformation Identity -> Maybe)
testMapRecord :: IO Bool
testMapRecord = do
  let recA = Anon.insert #x (Identity (10 :: Int)) emptyRecord
      recMapped = mapRecord (\(Identity n) -> Just n) recA
      val = getRecordField #x recMapped
  assertBool "mapRecord: natural transformation transforms Identity to Maybe (x = Just 10)" (val == Just 10)

-- Constrained mapping: cmapRecord
testCMapRecord :: IO Bool
testCMapRecord = do
  let recA = Anon.insert #x (Identity (10 :: Int)) emptyRecord
      recMapped = cmapRecord (Proxy @Num) (\(Identity n) -> Identity (n * 2)) recA
      val = runIdentity (getRecordField #x recMapped)
  assertBool "cmapRecord: constrained natural transformation doubles Num field (x = 20)" (val == 20)

-- Record update: setRecordField
testSetRecordField :: IO Bool
testSetRecordField = do
  let recA = Anon.insert #x (Identity (10 :: Int)) emptyRecord
      recUpdated = setRecordField #x (Identity (100 :: Int)) recA
      val = runIdentity (getRecordField #x recUpdated)
  assertBool "setRecordField: field updated successfully (x = 100)" (val == 100)

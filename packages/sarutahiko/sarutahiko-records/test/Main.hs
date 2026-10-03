{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.Fields.Datum (SchemaVersion (..))
import Sarutahiko.Records.Envelope
  ( ForwardBoundaryViolation (..)
  , RowKind (..)
  , WireEnvelope (..)
  , assertCanReserialize
  , canReserialize
  , mkWireEnvelope
  )
import Sarutahiko.Records.HKD.TriState
  ( TriState (..)
  , fromMaybe
  , fromOptional
  , fromTriState
  , isAbsent
  , isPresent
  , isPresentNull
  , toMaybe
  )

import Laws.CombinatorLaws (combinatorLawTests)

main :: IO ()
main = do
  putStrLn "=== Running sarutahiko-records Laws & Invariants Suite ==="
  rTriState <- testTriStateLaws
  rEnvelope <- testEnvelopeLaws
  rCombinators <- combinatorLawTests
  if rTriState && rEnvelope && rCombinators
    then do
      putStrLn "\nAll sarutahiko-records tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome sarutahiko-records tests FAILED."
      exitFailure

assertBool :: String -> Bool -> IO Bool
assertBool desc cond = do
  if cond
    then do
      putStrLn $ "  [PASS] " ++ desc
      pure True
    else do
      putStrLn $ "  [FAIL] " ++ desc
      pure False

-- CA1–CA3: TriState laws
testTriStateLaws :: IO Bool
testTriStateLaws = do
  putStrLn "--- TriState Laws (CA1–CA3) ---"
  let a = (Absent :: TriState Int)
      n = (PresentNull :: TriState Int)
      p = Present (42 :: Int)

  r1 <- assertBool "CA1: Three distinct states (Absent, PresentNull, Present)"
          (isAbsent a && isPresentNull n && isPresent p && not (isPresent a) && not (isPresent n))

  -- Applicative behavior:
  let fAbsent = (Absent :: TriState (Int -> Int))
      fNull = (PresentNull :: TriState (Int -> Int))
      fPres = Present (+1)

  r2 <- assertBool "CA2: Applicative preserve absence and null"
          (isAbsent (fAbsent <*> p) && isPresentNull (fNull <*> p) && isPresent (fPres <*> p))

  -- Conversions:
  let m1 = toMaybe a
      m2 = toMaybe n
      m3 = toMaybe p
      t1 = fromOptional (Nothing :: Maybe Int)
      t2 = fromMaybe (Nothing :: Maybe Int)

  r3 <- assertBool "CA2: Conversions roundtrip faithfully"
          (m1 == Nothing && m2 == Nothing && m3 == Just 42 && isAbsent t1 && isPresentNull t2)

  let folded = fromTriState "absent" "null" (\x -> "present " ++ show x) p
  r4 <- assertBool "CA1: fromTriState folds exhaustively" (folded == "present 42")

  pure (r1 && r2 && r3 && r4)

-- E3–E4: WireEnvelope laws
testEnvelopeLaws :: IO Bool
testEnvelopeLaws = do
  putStrLn "--- WireEnvelope Laws (E3–E4) ---"
  let raw = "{\"id\":1,\"unknown_future_field\":true}" :: BS.ByteString
      unknowns = Map.singleton "unknown_future_field" "true"
      envNewer = mkWireEnvelope RowKindEvent (SchemaVersion 1) (SchemaVersion 2) (1 :: Int) raw unknowns
      envSame  = mkWireEnvelope RowKindEvent (SchemaVersion 1) (SchemaVersion 1) (1 :: Int) raw unknowns

  -- E3: envRawBytes is preserved verbatim
  r1 <- assertBool "E3: Unparsed raw bytes preserved in envRawBytes" (envRawBytes envNewer == raw)

  -- E3: Unknown fields preserved in map
  r2 <- assertBool "E3: Unknown fields preserved in envUnknownFields" (Map.size (envUnknownFields envNewer) == 1)

  -- E4: Forward boundary check
  -- If local version is 1, and envelope was authored at version 2 -> CANNOT reserialize
  let canReserNewer = canReserialize (SchemaVersion 1) envNewer
      reserNewerCheck = assertCanReserialize (SchemaVersion 1) envNewer
  r3 <- assertBool "E4: Cannot reserialize payload from newer schema version"
          (not canReserNewer && reserNewerCheck == Left (ForwardBoundaryReserializationForbidden (SchemaVersion 1) (SchemaVersion 2)))

  -- If local version is 1, and envelope was authored at version 1 -> CAN reserialize
  let canReserSame = canReserialize (SchemaVersion 1) envSame
      reserSameCheck = assertCanReserialize (SchemaVersion 1) envSame
  r4 <- assertBool "E4: Can reserialize payload from same or older schema version"
          (canReserSame && reserSameCheck == Right ())

  pure (r1 && r2 && r3 && r4)

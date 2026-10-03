{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Data.Maybe (isJust)
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.Fields.Datum
  ( Deprecation (..)
  , FieldDatum (..)
  , FieldValidationError (..)
  , ForOlder (..)
  , SchemaVersion (..)
  , mkFieldDatum
  )
import Sarutahiko.Fields.Registry
  ( RegistryError (..)
  , SomeField (..)
  , lookupField
  , registerFields
  , registrySize
  )
import Sarutahiko.Fields.Witness
  ( mkFieldWitness
  , witnessSymbol
  , witnessVersion
  )

-- | Test runner verifying CD1 and CD2 contracts deterministically.
main :: IO ()
main = do
  putStrLn "=== Running sarutahiko-fields CD1–CD2 Property & Invariant Suite ==="
  results <- sequence
    [ testCD1InitialVersionNoDefault
    , testCD1SubsequentVersionRequiresFallback
    , testCD1SubsequentVersionWithFallbackPasses
    , testCD1DeprecationScheduleValidation
    , testCD1ZeroVersionForbidden
    , testCD2DeclareOncePasses
    , testCD2DuplicateConflictFails
    , testCD2IdempotentExactReDeclarationPasses
    , testWitnessMetadataConsistency
    ]
  if and results
    then do
      putStrLn "\nAll sarutahiko-fields invariant tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome sarutahiko-fields invariant tests FAILED."
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

-- CD1: Initial version (v1) field with NoDefault is valid.
testCD1InitialVersionNoDefault :: IO Bool
testCD1InitialVersionNoDefault = do
  let res = mkFieldDatum (Proxy @"seq") (SchemaVersion 1) Nothing (NoDefault :: ForOlder Int)
  case res of
    Right (_ :: FieldDatum "seq" Int) ->
      assertBool "CD1: Initial version v1 permits NoDefault" True
    Left err ->
      assertBool ("CD1: Initial version v1 failed with: " ++ show err) False

-- CD1: Subsequent version (> v1) field with NoDefault is rejected (violates E2).
testCD1SubsequentVersionRequiresFallback :: IO Bool
testCD1SubsequentVersionRequiresFallback = do
  let res = mkFieldDatum (Proxy @"seq") (SchemaVersion 2) Nothing (NoDefault :: ForOlder Int)
  case res of
    Left (MissingForOlderProvision (SchemaVersion 2)) ->
      assertBool "CD1: Version > v1 with NoDefault is rejected with MissingForOlderProvision" True
    _ ->
      assertBool "CD1: Expected MissingForOlderProvision on v2 NoDefault" False

-- CD1: Subsequent version (> v1) field with StaticDefault is accepted.
testCD1SubsequentVersionWithFallbackPasses :: IO Bool
testCD1SubsequentVersionWithFallbackPasses = do
  let res = mkFieldDatum (Proxy @"count") (SchemaVersion 2) Nothing (StaticDefault (0 :: Int))
  case res of
    Right (_ :: FieldDatum "count" Int) ->
      assertBool "CD1: Version > v1 with StaticDefault is accepted" True
    Left err ->
      assertBool ("CD1: Version > v1 StaticDefault failed: " ++ show err) False

-- CD1: Deprecation schedule validation (depSince <= depDropAt and depSince >= fdIntroVer).
testCD1DeprecationScheduleValidation :: IO Bool
testCD1DeprecationScheduleValidation = do
  let invalidDep1 = Deprecated (SchemaVersion 1) "Too early" (SchemaVersion 3)
      res1 = mkFieldDatum (Proxy @"foo") (SchemaVersion 2) (Just invalidDep1) (StaticDefault (0 :: Int))
  let invalidDep2 = Deprecated (SchemaVersion 3) "Inverted drop" (SchemaVersion 2)
      res2 = mkFieldDatum (Proxy @"foo") (SchemaVersion 2) (Just invalidDep2) (StaticDefault (0 :: Int))
  let validDep = Deprecated (SchemaVersion 2) "Normal deprecation" (SchemaVersion 4)
      res3 = mkFieldDatum (Proxy @"foo") (SchemaVersion 2) (Just validDep) (StaticDefault (0 :: Int))

  case (res1, res2, res3) of
    ( Left (InvalidDeprecationSchedule _ _)
      , Left (InvalidDeprecationSchedule _ _)
      , Right (_ :: FieldDatum "foo" Int)
      ) -> assertBool "CD1: Deprecation schedules strictly validated against intro and drop versions" True
    _ -> assertBool "CD1: Deprecation schedule validation failed" False

-- CD1: Version 0 is rejected.
testCD1ZeroVersionForbidden :: IO Bool
testCD1ZeroVersionForbidden = do
  let res = mkFieldDatum (Proxy @"zero") (SchemaVersion 0) Nothing (StaticDefault (10 :: Int))
  case res of
    Left ZeroSchemaVersion ->
      assertBool "CD1: SchemaVersion 0 rejected with ZeroSchemaVersion" True
    _ ->
      assertBool "CD1: Zero version was not rejected" False

-- CD2: Multiple distinct fields declare once and register successfully.
testCD2DeclareOncePasses :: IO Bool
testCD2DeclareOncePasses = do
  let mFd1 = mkFieldDatum (Proxy @"seq") (SchemaVersion 1) Nothing (NoDefault :: ForOlder Int)
      mFd2 = mkFieldDatum (Proxy @"actor") (SchemaVersion 1) Nothing (NoDefault :: ForOlder T.Text)
      mFd3 = mkFieldDatum (Proxy @"cause") (SchemaVersion 2) Nothing (StaticDefault (Nothing :: Maybe Int))

  case (mFd1, mFd2, mFd3) of
    (Right fd1, Right fd2, Right fd3) -> do
      let fields = [SomeField fd1, SomeField fd2, SomeField fd3]
      case registerFields fields of
        Right reg -> do
          let sz = registrySize reg
              f1 = lookupField "seq" reg
              f2 = lookupField "actor" reg
              f3 = lookupField "cause" reg
          assertBool "CD2: Registered distinct fields successfully into registry" (sz == 3 && all isJust [f1, f2, f3])
        Left err ->
          assertBool ("CD2: Registration failed unexpectedly: " ++ show err) False
    _ -> assertBool "CD2: Failed creating test field datums" False

-- CD2: Duplicate registration with conflicting types is rejected.
testCD2DuplicateConflictFails :: IO Bool
testCD2DuplicateConflictFails = do
  let mFdInt = mkFieldDatum (Proxy @"tag") (SchemaVersion 1) Nothing (NoDefault :: ForOlder Int)
      mFdText = mkFieldDatum (Proxy @"tag") (SchemaVersion 1) Nothing (NoDefault :: ForOlder T.Text)

  case (mFdInt, mFdText) of
    (Right fdInt, Right fdText) -> do
      let fields = [SomeField fdInt, SomeField fdText]
      case registerFields fields of
        Left (DuplicateFieldSymbol "tag" _ _) ->
          assertBool "CD2: Symbol collision with conflicting type correctly rejected" True
        other ->
          assertBool ("CD2: Expected DuplicateFieldSymbol, got: " ++ show other) False
    _ -> assertBool "CD2: Field creation failed" False

-- CD2: Idempotent re-declaration of exact identical field succeeds without error.
testCD2IdempotentExactReDeclarationPasses :: IO Bool
testCD2IdempotentExactReDeclarationPasses = do
  let mFd = mkFieldDatum (Proxy @"seq") (SchemaVersion 1) Nothing (NoDefault :: ForOlder Int)
  case mFd of
    Right fd -> do
      let fields = [SomeField fd, SomeField fd]
      case registerFields fields of
        Right reg ->
          assertBool "CD2: Idempotent re-declaration of identical field succeeds" (registrySize reg == 1)
        Left err ->
          assertBool ("CD2: Idempotent re-declaration failed: " ++ show err) False
    Left err -> assertBool ("CD2: Field creation failed: " ++ show err) False

-- Witness: FieldWitness maintains consistency with FieldDatum.
testWitnessMetadataConsistency :: IO Bool
testWitnessMetadataConsistency = do
  let mWit = mkFieldWitness (Proxy @"counter") (SchemaVersion 1) Nothing (NoDefault :: ForOlder Int)
  case mWit of
    Right wit -> do
      let sym = witnessSymbol wit
          ver = witnessVersion wit
      assertBool "Witness: FieldWitness properly reflects symbol and schema version" (sym == "counter" && ver == SchemaVersion 1)
    Left err -> assertBool ("Witness: Witness creation failed: " ++ show err) False

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Record.Anon (pattern (:=))
import Data.Text (Text)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Kogaki.Wire.Json.Lexer (JsonToken (..))
import Sarutahiko.Records.HKD.TriState (TriState (..))
import Sarutahiko.Schema.Compile ()
import Sarutahiko.Schema.Types
  ( DocField (..)
  , KnownRowSchema (..)
  , SchemaNode (..)
  , schemaNodeToJson
  )
import Sarutahiko.Schema.Validate
  ( SchemaValidationError (..)
  , validateJsonBytes
  , validateSchema
  )

main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runDoc = runAll || any (List.isInfixOf "DocrecordsExtraction") args

  putStrLn "=== Running sarutahiko-schema Invariant & Conformance Suite (TP-1.3) ==="
  rDoc <- if runDoc then testDocrecordsExtractionAndValidation else pure True

  if rDoc
    then do
      putStrLn "\nAll sarutahiko-schema tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome sarutahiko-schema tests FAILED."
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

-- ----------------------------------------------------------------------------
-- Test Row Definitions
-- ----------------------------------------------------------------------------

type ToolInvocationRow =
  '[ "tool_name"   := DocField "The unique name of the MCP tool to execute" Text
   , "concurrency" := DocField "Max concurrency limit" Int
   , "retry_count" := DocField "Optional retry attempts" (TriState Int)
   , "tags"        := [Text]
   ]

testDocrecordsExtractionAndValidation :: IO Bool
testDocrecordsExtractionAndValidation = do
  putStrLn "--- Docrecords Extraction & Offline Validation (Invariants 1 & 2) ---"
  results <- sequence
    [ testDocrecordsExtraction
    , testRequiredFieldPartitioning
    , testJsonSchemaSerialization
    , testInvariant1RemoteRefRejection
    , testValidationSuccessOnValidPayload
    , testValidationFailureOnMissingRequiredField
    , testValidationFailureOnTypeMismatch
    , testValidationFailureOnIntegerOutOfRange
    ]
  pure (and results)

-- 1. Invariant 2 (Docrecords Extraction): field docstrings populate description attribute
testDocrecordsExtraction :: IO Bool
testDocrecordsExtraction = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
  case schema of
    SchemaObject props _ -> do
      let hasToolDoc = case Map.lookup "tool_name" props of
            Just (SchemaAnnotated (Just doc) (SchemaString Nothing)) ->
              doc == "The unique name of the MCP tool to execute"
            _ -> False

          hasConcurDoc = case Map.lookup "concurrency" props of
            Just (SchemaAnnotated (Just doc) (SchemaInteger Nothing Nothing)) ->
              doc == "Max concurrency limit"
            _ -> False

          hasRetryDoc = case Map.lookup "retry_count" props of
            Just (SchemaAnnotated (Just doc) (SchemaInteger Nothing Nothing)) ->
              doc == "Optional retry attempts"
            _ -> False

      assertBool "Invariant 2 (Docrecords Extraction): compileRowSchema embeds docstrings into SchemaAnnotated"
        (hasToolDoc && hasConcurDoc && hasRetryDoc)
    _ -> assertBool "rowToSchema must produce SchemaObject" False

-- 2. Required fields must include mandatory fields and exclude optional (TriState)
testRequiredFieldPartitioning :: IO Bool
testRequiredFieldPartitioning = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
  case schema of
    SchemaObject _ reqs -> do
      let reqSet = reqs
          hasMandatory = "tool_name" `elem` reqSet
                      && "concurrency" `elem` reqSet
                      && "tags" `elem` reqSet
          omitsOptional = not ("retry_count" `elem` reqSet)
      assertBool "Docrecords: mandatory fields are required; TriState optional fields are omitted from required list"
        (hasMandatory && omitsOptional)
    _ -> assertBool "rowToSchema must produce SchemaObject" False

-- 3. Serialized JSON Schema format
testJsonSchemaSerialization :: IO Bool
testJsonSchemaSerialization = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
      jsonBytes = schemaNodeToJson schema
      hasDesc1 = "\"description\":\"The unique name of the MCP tool to execute\"" `BS.isInfixOf` jsonBytes
      hasDesc2 = "\"description\":\"Max concurrency limit\"" `BS.isInfixOf` jsonBytes
      hasType = "\"type\":\"object\"" `BS.isInfixOf` jsonBytes
  assertBool "JSON Schema serialization: embeds descriptions and schema types canonically"
    (hasDesc1 && hasDesc2 && hasType)

-- 4. Invariant 1 (No Network Fetch): Remote $ref is rejected
testInvariant1RemoteRefRejection :: IO Bool
testInvariant1RemoteRefRejection = do
  let remoteRef = SchemaRef "https://json-schema.org/draft/2020-12/schema"
      res = validateSchema remoteRef [TkString "foo"]
  case res of
    Left (ErrRemoteSchemaRefUnsupported uri) ->
      assertBool "Invariant 1 (No Network Fetch): Remote http/https $ref strictly rejected offline"
        (uri == "https://json-schema.org/draft/2020-12/schema")
    _ -> assertBool "Invariant 1: Remote $ref was not rejected!" False

-- 5. Validation passes on valid payload
testValidationSuccessOnValidPayload :: IO Bool
testValidationSuccessOnValidPayload = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
      validJson = "{\"tool_name\":\"calc\",\"concurrency\":4,\"tags\":[\"fast\",\"pure\"]}"
      res = validateJsonBytes schema validJson
  assertBool "Validation: valid payload satisfies schema"
    (res == Right ())

-- 6. Validation fails when required field is missing
testValidationFailureOnMissingRequiredField :: IO Bool
testValidationFailureOnMissingRequiredField = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
      missingJson = "{\"tool_name\":\"calc\",\"tags\":[]}" -- missing concurrency
      res = validateJsonBytes schema missingJson
  case res of
    Left (ErrMissingRequiredField fld) ->
      assertBool "Validation: missing required field correctly caught"
        (fld == "concurrency")
    _ -> assertBool "Validation did not catch missing required field!" False

-- 7. Validation fails on type mismatch
testValidationFailureOnTypeMismatch :: IO Bool
testValidationFailureOnTypeMismatch = do
  let schema = rowToSchema (Proxy @ToolInvocationRow)
      badTypeJson = "{\"tool_name\":\"calc\",\"concurrency\":\"four\",\"tags\":[]}"
      res = validateJsonBytes schema badTypeJson
  case res of
    Left (ErrTypeMismatch expected actual) ->
      assertBool "Validation: type mismatch caught (expected integer, got string)"
        (expected == "integer" && actual == "string")
    _ -> assertBool "Validation did not catch type mismatch!" False

-- 8. Validation fails on out-of-range integer
testValidationFailureOnIntegerOutOfRange :: IO Bool
testValidationFailureOnIntegerOutOfRange = do
  let boundedIntSchema = SchemaInteger (Just 1) (Just 100)
      resUnder = validateSchema boundedIntSchema [TkInt 0]
      resOver  = validateSchema boundedIntSchema [TkInt 150]
      underOk = case resUnder of Left (ErrNumberOutOfRange "below minimum" 0) -> True; _ -> False
      overOk  = case resOver  of Left (ErrNumberOutOfRange "above maximum" 150) -> True; _ -> False
  assertBool "Validation: integer bounds enforced (minimum 1, maximum 100)"
    (underOk && overOk)

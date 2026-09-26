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

import Data.Functor.Identity (Identity (..), runIdentity)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Record.Anon (pattern (:=))
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.Records.Combinators (getRecordField)

import Kogaki.Wire.Json.Decode
  ( decodeJson
  , decodeJsonEnvelope
  , decodeJsonRow
  , encodeJsonRow
  )
import Kogaki.Wire.Json.Lexer
  ( JsonToken (..)
  , lexJson
  , lexJsonEither
  )
import Kogaki.Wire.SSE.Parser
  ( SseEvent (..)
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  )
import Sarutahiko.Fields.Datum (SchemaVersion (..))
import Sarutahiko.Records.Envelope (WireEnvelope (..))
import Sarutahiko.Records.HKD.TriState (TriState (..))

-- | Main test runner supporting pattern filters (-p /JsonLexer/, -p /SseRoundTrip/).
main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runJson = runAll || any (List.isInfixOf "JsonLexer") args
      runSse  = runAll || any (List.isInfixOf "SseRoundTrip") args

  putStrLn "=== Running kogaki-wire Property & Invariant Suite (TP-1.1) ==="
  rJson <- if runJson then testJsonLexerAndDecoder else pure True
  rSse  <- if runSse  then testSseRoundTripEquivalence else pure True

  if rJson && rSse
    then do
      putStrLn "\nAll kogaki-wire invariant tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome kogaki-wire invariant tests FAILED."
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

testJsonLexerAndDecoder :: IO Bool
testJsonLexerAndDecoder = do
  putStrLn "--- JsonLexer & Row Decoding Invariants (Invariant 1) ---"
  results <- sequence
    [ testLexerEmptyStructures
    , testLexerPrimitivesAndEscapes
    , testLexerNestedStructure
    , testZeroIntermediateAstRowDecoding
    , testAbsenceFunctorMergePatchPreservation
    , testWireEnvelopeUnknownFieldPreservation
    , testCanonicalLexicographicalEncoding
    ]
  pure (and results)

testLexerEmptyStructures :: IO Bool
testLexerEmptyStructures = do
  let tksObj = lexJson "{}"
      tksArr = lexJson "[]"
  b1 <- assertBool "JsonLexer: empty object emits [TkObjectOpen, TkObjectClose]"
    (tksObj == [TkObjectOpen, TkObjectClose])
  b2 <- assertBool "JsonLexer: empty array emits [TkArrayOpen, TkArrayClose]"
    (tksArr == [TkArrayOpen, TkArrayClose])
  pure (b1 && b2)

testLexerPrimitivesAndEscapes :: IO Bool
testLexerPrimitivesAndEscapes = do
  let json = "{\"int\": -42, \"float\": 3.14, \"str\": \"hello\\nworld\\u0021\", \"b\": true, \"nil\": null}"
      tks = lexJson json
      expected =
        [ TkObjectOpen
        , TkKey "int"
        , TkInt (-42)
        , TkKey "float"
        , TkDouble 3.14
        , TkKey "str"
        , TkString "hello\nworld!"
        , TkKey "b"
        , TkBool True
        , TkKey "nil"
        , TkNull
        , TkObjectClose
        ]
      mSingle = decodeJson "12345"
      isErr = case lexJsonEither "{\"unclosed" of Left _ -> True; Right _ -> False
  b1 <- assertBool "JsonLexer: correctly tokenizes numbers, escapes, bools, and null"
    (tks == expected)
  b2 <- assertBool "JsonLexer: decodeJson extracts single primitive token"
    (mSingle == Just (TkInt 12345))
  b3 <- assertBool "JsonLexer: lexJsonEither surfaces error on malformed JSON"
    isErr
  pure (b1 && b2 && b3)

testLexerNestedStructure :: IO Bool
testLexerNestedStructure = do
  let json = "{\"tool\": \"calculator\", \"args\": {\"numbers\": [1, 2, 3]}}"
      tks = lexJson json
      expected =
        [ TkObjectOpen
        , TkKey "tool"
        , TkString "calculator"
        , TkKey "args"
        , TkObjectOpen
        , TkKey "numbers"
        , TkArrayOpen
        , TkInt 1
        , TkInt 2
        , TkInt 3
        , TkArrayClose
        , TkObjectClose
        , TkObjectClose
        ]
  assertBool "JsonLexer: nested objects and arrays maintain structural fidelity"
    (tks == expected)

type SimpleRow =
  '[ "name"   := Text
   , "count"  := Int
   , "score"  := Double
   , "online" := Bool
   ]

testZeroIntermediateAstRowDecoding :: IO Bool
testZeroIntermediateAstRowDecoding = do
  let rawJson = "{\"score\": 98.5, \"online\": true, \"count\": 7, \"name\": \"Nadia\"}"
      mRec = decodeJsonRow @SimpleRow rawJson
  case mRec of
    Nothing -> assertBool "Invariant 1: decodeJsonRow directly decoded simple row" False
    Just rec -> do
      let nm = runIdentity (getRecordField #name rec)
          ct = runIdentity (getRecordField #count rec)
          sc = runIdentity (getRecordField #score rec)
          on = runIdentity (getRecordField #online rec)
      assertBool "Invariant 1: row values hydrated with zero intermediate Value AST"
        (nm == "Nadia" && ct == 7 && sc == 98.5 && on == True)

type TriRow =
  '[ "mandatory" := Text
   , "optional"  := TriState Text
   ]

testAbsenceFunctorMergePatchPreservation :: IO Bool
testAbsenceFunctorMergePatchPreservation = do
  -- Case A: Key omitted on wire -> Absent
  let jsonAbsent = "{\"mandatory\": \"keep\"}"
      mRecA = decodeJsonRow @TriRow jsonAbsent
      isAbsentOk = case mRecA of
        Just rec -> case runIdentity (getRecordField #optional rec) of Absent -> True; _ -> False
        Nothing  -> False

  -- Case B: Key present as null -> PresentNull
  let jsonNull = "{\"mandatory\": \"keep\", \"optional\": null}"
      mRecB = decodeJsonRow @TriRow jsonNull
      isNullOk = case mRecB of
        Just rec -> case runIdentity (getRecordField #optional rec) of PresentNull -> True; _ -> False
        Nothing  -> False

  -- Case C: Key present with value -> Present val
  let jsonVal = "{\"mandatory\": \"keep\", \"optional\": \"updated\"}"
      mRecC = decodeJsonRow @TriRow jsonVal
      isValOk = case mRecC of
        Just rec -> case runIdentity (getRecordField #optional rec) of Present "updated" -> True; _ -> False
        Nothing  -> False

  assertBool "CA1–CA3: TriState correctly distinguishes Absent vs PresentNull vs Present"
    (isAbsentOk && isNullOk && isValOk)

testWireEnvelopeUnknownFieldPreservation :: IO Bool
testWireEnvelopeUnknownFieldPreservation = do
  let raw = "{\"name\": \"agent\", \"count\": 1, \"score\": 0.0, \"online\": false, \"future_field\": 999}"
      eEnv = decodeJsonEnvelope @SimpleRow (SchemaVersion 1) raw
  case eEnv of
    Left err -> assertBool ("E3/E4: envelope decoding failed: " ++ T.unpack err) False
    Right env -> do
      let unks = envUnknownFields env
          hasUnknown = Map.size unks == 1
                    && Map.lookup "future_field" unks == Just "999"
          rawMatches = envRawBytes env == raw
      assertBool "E3/E4: unknown wire fields preserved into WireEnvelope with raw bytes"
        (hasUnknown && rawMatches)

testCanonicalLexicographicalEncoding :: IO Bool
testCanonicalLexicographicalEncoding = do
  let rawJson = "{\"score\": 1.0, \"online\": true, \"count\": 2, \"name\": \"alpha\"}"
  case decodeJsonRow @SimpleRow rawJson of
    Nothing -> assertBool "Law L4: decodeJsonRow failed" False
    Just rec -> do
      let encoded = encodeJsonRow rec
          -- Lexicographical order: count, name, online, score
          expected = "{\"count\":2,\"name\":\"alpha\",\"online\":true,\"score\":1.0}"
      assertBool "Law L4: canonical row encoder sorts keys lexicographically without whitespace"
        (encoded == expected)

-- ----------------------------------------------------------------------------
-- Test Group: SSE Streaming Framing & Roundtrip (Invariant 2)
-- ----------------------------------------------------------------------------

testSseRoundTripEquivalence :: IO Bool
testSseRoundTripEquivalence = do
  putStrLn "--- Server-Sent Events (SSE) Round-Trip Equivalence (Invariant 2) ---"
  results <- sequence
    [ testSseSingleEventRoundTrip
    , testSseMultiLineDataRoundTrip
    , testSseMultipleEventsInStream
    , testSseOptionalFieldsHandling
    ]
  pure (and results)

testSseSingleEventRoundTrip :: IO Bool
testSseSingleEventRoundTrip = do
  let evt = SseEvent
        { sseId    = Just "evt-001"
        , sseEvent = Just "delta"
        , sseData  = "{\"text\": \"completion snippet\"}"
        , sseRetry = Just 3000
        }
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: single SSE event satisfies bit-identical roundtrip equivalence"
    (parsed == [evt])

testSseMultiLineDataRoundTrip :: IO Bool
testSseMultiLineDataRoundTrip = do
  let evt = SseEvent
        { sseId    = Just "42"
        , sseEvent = Just "chunk"
        , sseData  = "line 1\nline 2\nline 3"
        , sseRetry = Nothing
        }
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: multi-line SSE data unfolds and parses with exact newline preservation"
    (parsed == [evt])

testSseMultipleEventsInStream :: IO Bool
testSseMultipleEventsInStream = do
  let ev1 = SseEvent (Just "1") (Just "start") "begin" Nothing
      ev2 = SseEvent Nothing (Just "update") "in-progress" (Just 1000)
      ev3 = SseEvent (Just "2") (Just "done") "finished" Nothing
      events = [ev1, ev2, ev3]
      streamBytes = renderSseStream events
      parsed = parseSseStream streamBytes
  assertBool "Invariant 2: multi-event SSE stream parses all discrete events in exact order"
    (parsed == events)

testSseOptionalFieldsHandling :: IO Bool
testSseOptionalFieldsHandling = do
  let evt = SseEvent Nothing Nothing "bare data payload" Nothing
      rendered = renderSseEvent evt
      parsed = parseSseStream rendered
  assertBool "Invariant 2: bare SSE data payload with omitted optional fields roundtrips cleanly"
    (parsed == [evt])

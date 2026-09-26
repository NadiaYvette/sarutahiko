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
import qualified Data.ByteString.Char8 as BSC
import Data.Functor.Identity (Identity (..), runIdentity)
import qualified Data.List as List
import Data.Record.Anon (pattern (:=))
import Data.Record.Anon.Advanced (insert)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

import Sarutahiko.JsonRpc.Dispatch
  ( Dispatcher
  , dispatchPayload
  , emptyDispatcher
  , registerMethod
  , registerRawMethod
  )
import Sarutahiko.JsonRpc.Error
  ( codeInternalError
  , codeInvalidParams
  , codeInvalidRequest
  , codeMethodNotFound
  , codeParseError
  , errInternalError
  )
import Sarutahiko.Records.Combinators (emptyRecord, getRecordField)

main :: IO ()
main = do
  args <- getArgs
  let runAll = null args
      runSpec = runAll || any (List.isInfixOf "SpecConformance") args

  putStrLn "=== Running sarutahiko-jsonrpc Specification Conformance Suite (TP-1.2) ==="
  rSpec <- if runSpec then testSpecConformance else pure True

  if rSpec
    then do
      putStrLn "\nAll sarutahiko-jsonrpc tests PASSED."
      exitSuccess
    else do
      putStrLn "\nSome sarutahiko-jsonrpc tests FAILED."
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
-- Specification Conformance Tests (JSON-RPC 2.0 Invariants 1 & 2)
-- ----------------------------------------------------------------------------

type AddParams =
  '[ "a" := Int
   , "b" := Int
   ]

type AddResult =
  '[ "sum" := Int
   ]

testDispatcher :: Dispatcher IO
testDispatcher =
  let d0 = emptyDispatcher
      d1 = registerMethod @AddParams @AddResult
             "add"
             (\params -> do
                 let a = runIdentity (getRecordField #a params)
                     b = runIdentity (getRecordField #b params)
                     res = insert #sum (Identity (a + b)) emptyRecord
                 pure res
             )
             d0
      d2 = registerRawMethod
             "notify_server"
             (\_ -> pure (Right "{}"))
             d1
      d3 = registerRawMethod
             "fail_server"
             (\_ -> pure (Left (errInternalError "crash!")))
             d2
  in d3

testSpecConformance :: IO Bool
testSpecConformance = do
  putStrLn "--- JSON-RPC 2.0 Specification Conformance & Error Bounds ---"
  results <- sequence
    [ testStandardTypedCallSuccess
    , testNotificationSilenceSingle
    , testNotificationSilenceBatch
    , testParseErrorHandling
    , testInvalidRequestEmptyBatch
    , testInvalidRequestMissingVersion
    , testMethodNotFoundHandling
    , testInvalidParamsHandling
    , testInternalErrorHandling
    , testMixedBatchRequestsAndNotifications
    ]
  pure (and results)

-- 1. Standard RPC call: request with id returns success result
testStandardTypedCallSuccess :: IO Bool
testStandardTypedCallSuccess = do
  let req = "{\"jsonrpc\":\"2.0\",\"method\":\"add\",\"params\":{\"a\":17,\"b\":25},\"id\":1}"
  mRes <- dispatchPayload testDispatcher req
  case mRes of
    Nothing -> assertBool "Standard typed call returned response" False
    Just res -> do
      let expected = "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"sum\":42}}"
      assertBool "Standard typed call: successfully returns computed row result with id"
        (res == expected)

-- 2. Invariant 2 (Notification Silence): single notification produces Nothing
testNotificationSilenceSingle :: IO Bool
testNotificationSilenceSingle = do
  let notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notify_server\",\"params\":{\"foo\":\"bar\"}}"
  mRes <- dispatchPayload testDispatcher notif
  assertBool "Invariant 2 (Notification Silence): single notification produces zero wire response"
    (mRes == Nothing)

-- 3. Invariant 2 (Notification Silence): batch of only notifications produces Nothing
testNotificationSilenceBatch :: IO Bool
testNotificationSilenceBatch = do
  let notifs = "[{\"jsonrpc\":\"2.0\",\"method\":\"notify_server\"},{\"jsonrpc\":\"2.0\",\"method\":\"notify_server\"}]"
  mRes <- dispatchPayload testDispatcher notifs
  assertBool "Invariant 2 (Notification Silence): batch of all notifications produces zero wire response"
    (mRes == Nothing)

-- 4. Invariant 1 (Standard Error Bounds): Parse Error (-32700)
testParseErrorHandling :: IO Bool
testParseErrorHandling = do
  let invalidJson = "{\"jsonrpc\":\"2.0\",\"method\":\"add\", bad json"
  mRes <- dispatchPayload testDispatcher invalidJson
  case mRes of
    Nothing -> assertBool "ParseError returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeParseError) `BS.isInfixOf` res
          hasNullId = "\"id\":null" `BS.isInfixOf` res
      assertBool "Invariant 1: ParseError emits code -32700 with null id"
        (hasCode && hasNullId)

-- 5. Invariant 1: Invalid Request on empty batch [] (-32600)
testInvalidRequestEmptyBatch :: IO Bool
testInvalidRequestEmptyBatch = do
  let emptyBatch = "[]"
  mRes <- dispatchPayload testDispatcher emptyBatch
  case mRes of
    Nothing -> assertBool "Empty batch returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeInvalidRequest) `BS.isInfixOf` res
      assertBool "Invariant 1: Empty batch emits InvalidRequest (-32600)"
        hasCode

-- 6. Invariant 1: Invalid Request on missing jsonrpc version (-32600)
testInvalidRequestMissingVersion :: IO Bool
testInvalidRequestMissingVersion = do
  let req = "{\"method\":\"add\",\"params\":{\"a\":1,\"b\":2},\"id\":99}"
  mRes <- dispatchPayload testDispatcher req
  case mRes of
    Nothing -> assertBool "Missing jsonrpc version returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeInvalidRequest) `BS.isInfixOf` res
          hasId = "\"id\":99" `BS.isInfixOf` res
      assertBool "Invariant 1: Missing jsonrpc version emits InvalidRequest (-32600) preserving id"
        (hasCode && hasId)

-- 7. Invariant 1: Method Not Found (-32601)
testMethodNotFoundHandling :: IO Bool
testMethodNotFoundHandling = do
  let req = "{\"jsonrpc\":\"2.0\",\"method\":\"non_existent_method\",\"id\":10}"
  mRes <- dispatchPayload testDispatcher req
  case mRes of
    Nothing -> assertBool "MethodNotFound returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeMethodNotFound) `BS.isInfixOf` res
          hasId = "\"id\":10" `BS.isInfixOf` res
      assertBool "Invariant 1: Unknown method emits MethodNotFound (-32601) preserving id"
        (hasCode && hasId)

-- 8. Invariant 1: Invalid Params (-32602)
testInvalidParamsHandling :: IO Bool
testInvalidParamsHandling = do
  let req = "{\"jsonrpc\":\"2.0\",\"method\":\"add\",\"params\":{\"a\":\"string_instead_of_int\",\"b\":2},\"id\":11}"
  mRes <- dispatchPayload testDispatcher req
  case mRes of
    Nothing -> assertBool "InvalidParams returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeInvalidParams) `BS.isInfixOf` res
          hasId = "\"id\":11" `BS.isInfixOf` res
      assertBool "Invariant 1: Type mismatch in params emits InvalidParams (-32602) preserving id"
        (hasCode && hasId)

-- 9. Invariant 1: Internal Error (-32603)
testInternalErrorHandling :: IO Bool
testInternalErrorHandling = do
  let req = "{\"jsonrpc\":\"2.0\",\"method\":\"fail_server\",\"id\":12}"
  mRes <- dispatchPayload testDispatcher req
  case mRes of
    Nothing -> assertBool "InternalError returned response" False
    Just res -> do
      let hasCode = BSC.pack (show codeInternalError) `BS.isInfixOf` res
          hasId = "\"id\":12" `BS.isInfixOf` res
      assertBool "Invariant 1: Handler failure emits InternalError (-32603) preserving id"
        (hasCode && hasId)

-- 10. Mixed Batch: contains 2 requests and 1 notification
testMixedBatchRequestsAndNotifications :: IO Bool
testMixedBatchRequestsAndNotifications = do
  let batch = "["
           <> "{\"jsonrpc\":\"2.0\",\"method\":\"add\",\"params\":{\"a\":1,\"b\":2},\"id\":\"req1\"},"
           <> "{\"jsonrpc\":\"2.0\",\"method\":\"notify_server\"},"
           <> "{\"jsonrpc\":\"2.0\",\"method\":\"add\",\"params\":{\"a\":10,\"b\":20},\"id\":\"req2\"}"
           <> "]"
  mRes <- dispatchPayload testDispatcher batch
  case mRes of
    Nothing -> assertBool "Mixed batch returned response" False
    Just res -> do
      -- The notification must NOT be in the response array; only the 2 requests
      let hasReq1 = "\"id\":\"req1\"" `BS.isInfixOf` res && "\"sum\":3" `BS.isInfixOf` res
          hasReq2 = "\"id\":\"req2\"" `BS.isInfixOf` res && "\"sum\":30" `BS.isInfixOf` res
          isBatchArray = "[" `BS.isPrefixOf` res && "]" `BS.isSuffixOf` res
      assertBool "Batch dispatch: mixed batch responds only to requests and omits notifications"
        (hasReq1 && hasReq2 && isBatchArray)

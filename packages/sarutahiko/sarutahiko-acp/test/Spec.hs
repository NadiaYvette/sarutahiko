{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.ACP

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko ACP Test Suite"
  [ testProperty "ACP initialize handshake succeeds with valid capabilities" prop_acp_initialize
  , testProperty "ACP session prompt roundtrip dispatches response" prop_acp_prompt
  , testProperty "ACP tools call executes tool and returns output" prop_acp_tool_call
  , testProperty "ACP unknown method returns error code -32601" prop_acp_unknown_method
  ]

-- | Initialize handshake returns server info and protocol version.
prop_acp_initialize :: Property
prop_acp_initialize = property $ do
  reqId <- forAll $ Gen.int (Range.linear 1 1000)
  let req = "{\"jsonrpc\":\"2.0\",\"id\":" <> BSC.pack (show reqId) <> ",\"method\":\"initialize\",\"params\":{}}"
  resp <- evalIO $ dispatchAcpPayload req
  assert ("\"jsonrpc\":\"2.0\"" `BSC.isInfixOf` resp)
  assert (BSC.pack (show reqId) `BSC.isInfixOf` resp)
  assert ("\"protocolVersion\":\"2024-11-05\"" `BSC.isInfixOf` resp)
  assert ("\"serverInfo\"" `BSC.isInfixOf` resp)

-- | Session prompt receives echo response.
prop_acp_prompt :: Property
prop_acp_prompt = property $ do
  reqId <- forAll $ Gen.int (Range.linear 1 1000)
  sid <- forAll $ Gen.text (Range.linear 3 10) Gen.alphaNum
  prompt <- forAll $ Gen.text (Range.linear 1 30) Gen.alphaNum
  let req = "{\"jsonrpc\":\"2.0\",\"id\":" <> BSC.pack (show reqId)
         <> ",\"method\":\"session/prompt\",\"params\":{\"sessionId\":\""
         <> BSC.pack (T.unpack sid) <> "\",\"prompt\":\"" <> BSC.pack (T.unpack prompt) <> "\"}}"
  resp <- evalIO $ dispatchAcpPayload req
  assert ("\"jsonrpc\":\"2.0\"" `BSC.isInfixOf` resp)
  assert (BSC.pack (show reqId) `BSC.isInfixOf` resp)
  assert ("\"text\"" `BSC.isInfixOf` resp)

-- | Tools call dispatches and returns tool result.
prop_acp_tool_call :: Property
prop_acp_tool_call = property $ do
  reqId <- forAll $ Gen.int (Range.linear 1 1000)
  callId <- forAll $ Gen.text (Range.linear 3 8) Gen.alphaNum
  toolName <- forAll $ Gen.text (Range.linear 3 12) Gen.alphaNum
  let req = "{\"jsonrpc\":\"2.0\",\"id\":" <> BSC.pack (show reqId)
         <> ",\"method\":\"tools/call\",\"params\":{\"callId\":\""
         <> BSC.pack (T.unpack callId) <> "\",\"name\":\"" <> BSC.pack (T.unpack toolName)
         <> "\",\"arguments\":\"{}\"}}"
  resp <- evalIO $ dispatchAcpPayload req
  assert ("\"jsonrpc\":\"2.0\"" `BSC.isInfixOf` resp)
  assert ("\"output\"" `BSC.isInfixOf` resp)
  assert ("\"isError\":false" `BSC.isInfixOf` resp)

-- | Unknown method produces JSON-RPC method not found error (-32601).
prop_acp_unknown_method :: Property
prop_acp_unknown_method = property $ do
  reqId <- forAll $ Gen.int (Range.linear 1 1000)
  let req = "{\"jsonrpc\":\"2.0\",\"id\":" <> BSC.pack (show reqId) <> ",\"method\":\"unknown/method\",\"params\":{}}"
  resp <- evalIO $ dispatchAcpPayload req
  assert ("\"jsonrpc\":\"2.0\"" `BSC.isInfixOf` resp)
  assert ("-32601" `BSC.isInfixOf` resp)

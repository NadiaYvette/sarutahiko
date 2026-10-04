{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.TUI

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko TUI Test Suite"
  [ testProperty "TUI character input & backspace updates buffer" prop_input_buffer
  , testProperty "TUI enter submits prompt and transitions to streaming" prop_submit_prompt
  , testProperty "TUI streaming tokens accumulate monotonically" prop_streaming_tokens
  , testProperty "TUI cancellation transitions to cancelled and emits action" prop_cancellation
  , testProperty "TUI JSON-RPC request formatting conforms to spec" prop_jsonrpc_format
  , testProperty "TUI view rendering produces structured layout" prop_view_render
  ]

-- | Typing characters appends to input buffer, backspace removes characters.
prop_input_buffer :: Property
prop_input_buffer = property $ do
  chars <- forAll $ Gen.string (Range.linear 1 50) Gen.alphaNum
  let st0 = initialTuiState "test-session"
      stAfterChars = foldl (\s c -> fst (stepTui (EvChar c) s)) st0 chars
  tsInputBuffer stAfterChars === T.pack chars

  let stAfterBackspace = fst (stepTui EvBackspace stAfterChars)
  tsInputBuffer stAfterBackspace === T.pack (init chars)

-- | Enter submits non-empty prompt and transitions to streaming.
prop_submit_prompt :: Property
prop_submit_prompt = property $ do
  prompt <- forAll $ Gen.text (Range.linear 1 40) Gen.alphaNum
  let st0 = (initialTuiState "test-session") { tsInputBuffer = prompt }
      (st1, action) = stepTui EvEnter st0
  tsStatus st1 === TuiStreaming
  tsInputBuffer st1 === ""
  action === ActSubmitPrompt prompt
  length (tsHistory st1) === 1
  msgContent (last (tsHistory st1)) === prompt

-- | Streaming tokens accumulate in active response.
prop_streaming_tokens :: Property
prop_streaming_tokens = property $ do
  chunks <- forAll $ Gen.list (Range.linear 1 10) (Gen.text (Range.linear 1 20) Gen.alphaNum)
  let st0 = (initialTuiState "test-session") { tsStatus = TuiStreaming }
      stFinal = foldl (\s chunk -> fst (stepTui (EvTokenChunk chunk) s)) st0 chunks
  tsActiveResponse stFinal === T.concat chunks
  tsStatus stFinal === TuiStreaming

-- | Cancellation during streaming transitions to cancelled and returns ActSendCancel.
prop_cancellation :: Property
prop_cancellation = property $ do
  partialResp <- forAll $ Gen.text (Range.linear 0 30) Gen.alphaNum
  let st0 = (initialTuiState "test-session")
        { tsStatus = TuiStreaming
        , tsActiveResponse = partialResp
        }
      (st1, action) = stepTui EvCancel st0
  tsStatus st1 === TuiCancelled
  action === ActSendCancel
  length (tsHistory st1) === 1

-- | Formatted turn request contains valid JSON-RPC 2.0 structure.
prop_jsonrpc_format :: Property
prop_jsonrpc_format = property $ do
  reqId <- forAll $ Gen.int64 (Range.linear 1 10000)
  sid <- forAll $ Gen.text (Range.linear 3 15) Gen.alphaNum
  prompt <- forAll $ Gen.text (Range.linear 1 50) Gen.alphaNum
  let bytes = formatTurnRequest reqId sid prompt
  assert ("\"jsonrpc\":\"2.0\"" `BSC.isInfixOf` bytes)
  assert ("\"method\":\"agent/turn\"" `BSC.isInfixOf` bytes)
  assert (BSC.pack (show reqId) `BSC.isInfixOf` bytes)

-- | View rendering produces non-empty text containing session identifier.
prop_view_render :: Property
prop_view_render = property $ do
  sid <- forAll $ Gen.text (Range.linear 3 15) Gen.alphaNum
  let st = initialTuiState sid
      rendered = renderTuiView 80 24 st
  assert (not (T.null rendered))
  assert (sid `T.isInfixOf` rendered)

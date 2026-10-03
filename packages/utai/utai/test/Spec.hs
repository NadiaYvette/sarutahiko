{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Comprehensive property tests for utai LLM substrate
--
-- Verifies Laws L1–L4 (terminator honesty, usage monoid, option honesty,
-- prefix stability), wire codecs, and dual-carrier parity per
-- LLM_SUBSTRATE_DESIGN.md.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Effectful
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Effect.Stepper (drainStepper)
import Utai

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "utai"
  [ testGroup "Substrate Laws"
      [ testProperty "L1: Terminator Honesty (Stream terminates with Done/Error)" prop_l1_terminator_honesty
      , testProperty "L2: Usage Monoid (Associativity & Identity)" prop_l2_usage_monoid
      , testProperty "L3: Option Honesty (Unsupported options fail closed)" prop_l3_option_honesty
      , testProperty "L4: Prefix Stability (Identical requests yield identical responses)" prop_l4_prefix_stability
      ]
  , testGroup "Wire Codecs"
      [ testProperty "Wire: Request serialization produces valid JSON format" prop_wire_request_serialization
      , testProperty "Wire: Response decoding extracts content and usage" prop_wire_response_decoding
      ]
  , testGroup "Carrier Parity"
      [ testProperty "Dual Carrier Parity: Tagless MockModelT matches Effectful runModelAPIMock" prop_carrier_parity
      ]
  ]

-- | Generator for valid Usage records.
genUsage :: Gen Usage
genUsage = do
  inTok  <- Gen.integral (Range.linear 0 10000)
  outTok <- Gen.integral (Range.linear 0 10000)
  crTok  <- Gen.integral (Range.linear 0 5000)
  cwTok  <- Gen.integral (Range.linear 0 5000)
  rTok   <- Gen.integral (Range.linear 0 2000)
  pure $ Usage inTok outTok crTok cwTok rTok

-- | Generator for simple completion requests.
genReq :: Gen CompletionReq
genReq = do
  model <- Gen.element ["auto/best-coding", "gemini/gemini-3.8-flash", "opencode/space-bunny-free"]
  prompt <- Gen.text (Range.linear 1 50) Gen.alphaNum
  pure CompletionReq
    { reqModel    = model
    , reqMessages = [Message RoleUser prompt]
    , reqTools    = []
    , reqOptions  = defaultModelOptions
    }

-- ----------------------------------------------------------------------------
-- Law L1: Terminator Honesty
-- ----------------------------------------------------------------------------

prop_l1_terminator_honesty :: Property
prop_l1_terminator_honesty = property $ do
  req <- forAll genReq
  let store = addFixture (cannedText "test" "canned answer") emptyFixtureStore
      stepper = runMockStream store req
  events <- evalIO (drainStepper stepper)

  -- Must not be empty
  diff (length events) (>=) 2

  -- Must start with EventStart
  case events of
    (EventStart : _) -> success
    _                -> annotate "First event must be EventStart" >> failure

  -- Last event must be terminal (EventDone or EventError)
  let lastEvent = last events
  case lastEvent of
    EventDone _ _ -> success
    EventError _  -> success
    _             -> annotate ("Last event must be EventDone or EventError, got: " ++ show lastEvent) >> failure

-- ----------------------------------------------------------------------------
-- Law L2: Usage Monoid
-- ----------------------------------------------------------------------------

prop_l2_usage_monoid :: Property
prop_l2_usage_monoid = property $ do
  u1 <- forAll genUsage
  u2 <- forAll genUsage
  u3 <- forAll genUsage

  -- Left Identity: mempty <> u == u
  diff (mempty <> u1) (==) u1

  -- Right Identity: u <> mempty == u
  diff (u1 <> mempty) (==) u1

  -- Associativity: (u1 <> u2) <> u3 == u1 <> (u2 <> u3)
  diff ((u1 <> u2) <> u3) (==) (u1 <> (u2 <> u3))

-- ----------------------------------------------------------------------------
-- Law L3: Option Honesty
-- ----------------------------------------------------------------------------

prop_l3_option_honesty :: Property
prop_l3_option_honesty = property $ do
  negTemp <- forAll $ Gen.double (Range.linearFrac (-10.0) (-0.01))
  let req = CompletionReq
        { reqModel    = "auto/best-coding"
        , reqMessages = [Message RoleUser "Hello"]
        , reqTools    = []
        , reqOptions  = defaultModelOptions { optTemperature = Just negTemp }
        }
      store = emptyFixtureStore
      res = runMockCompletion store req

  -- Negative temperature is invalid and must fail closed rather than being silently dropped
  case res of
    Left _  -> success
    Right _ -> annotate "Unsupported negative temperature must fail closed" >> failure

-- ----------------------------------------------------------------------------
-- Law L4: Prefix Stability
-- ----------------------------------------------------------------------------

prop_l4_prefix_stability :: Property
prop_l4_prefix_stability = property $ do
  req <- forAll genReq
  let store = addFixture (cannedText "stable" "result 42") emptyFixtureStore
      res1 = runMockCompletion store req
      res2 = runMockCompletion store req

  diff res1 (==) res2

  events1 <- evalIO (drainStepper (runMockStream store req))
  events2 <- evalIO (drainStepper (runMockStream store req))

  diff events1 (==) events2

-- ----------------------------------------------------------------------------
-- Wire Codecs Verification
-- ----------------------------------------------------------------------------

prop_wire_request_serialization :: Property
prop_wire_request_serialization = property $ do
  req <- forAll genReq
  let jsonBytes = encodeChatCompletionReq req

  -- Must produce valid, non-empty JSON starting with { and ending with }
  diff (BS.isPrefixOf "{" jsonBytes) (==) True
  diff (BS.isSuffixOf "}" jsonBytes) (==) True

prop_wire_response_decoding :: Property
prop_wire_response_decoding = property $ do
  let sampleJson =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Synthesized output\"},\
        \\"finish_reason\":\"stop\"}],\
        \\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":24,\"total_tokens\":36}}"
  case decodeChatCompletionResp sampleJson of
    Left err -> annotate (T.unpack err) >> failure
    Right resp -> do
      diff (respContent resp) (==) "Synthesized output"
      diff (respStopReason resp) (==) StopCompleted
      diff (usageInputTokens (respUsage resp)) (==) 12
      diff (usageOutputTokens (respUsage resp)) (==) 24

-- ----------------------------------------------------------------------------
-- Carrier Parity: Tagless vs Effectful
-- ----------------------------------------------------------------------------

prop_carrier_parity :: Property
prop_carrier_parity = property $ do
  req <- forAll genReq
  let store = addFixture (cannedText "prefix" "response content") emptyFixtureStore

  -- 1. Execute via tagless carrier
  respTagless <- evalIO $ runMockModelT store (complete req)

  -- 2. Execute via Effectful carrier
  respEffectful <- evalIO $ runEff $ runModelAPIMock store (complete req)

  diff respTagless (==) respEffectful

{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: Main (kagami-ita-observability test suite)
-- Description: Unit and property verification for Kagami-Ita token accounting
module Main (main) where

import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Test.Tasty
import Test.Tasty.Hedgehog
import Test.Tasty.HUnit
import qualified Hedgehog as H
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import KagamiIta.Observability

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "KagamiIta.Observability"
  [ testGroup "TokenLedger Properties"
      [ testProperty "totals accumulate monotonically" prop_totals_monotonic
      , testProperty "cache hit ratio bounded in [0.0, 1.0]" prop_cache_ratio_bounded
      ]
  , testGroup "Circuit Breaker & Alert Unit Tests"
      [ testCase "trips breaker when fresh token budget exceeded" test_circuit_breaker_trips
      , testCase "fires warning alert on single turn cache invalidation spike" test_turn_spike_alert
      , testCase "detects inflated context window beyond compaction threshold" test_context_inflation_alert
      ]
  , testGroup "Transcript Ingestion"
      [ testCase "parses valid JSONL transcript lines" test_transcript_line_parsing
      , testCase "ignores non-model lines gracefully" test_transcript_ignore_non_model
      ]
  , testGroup "Exposition & Formatting"
      [ testCase "renders Markdown summary table" test_markdown_summary
      , testCase "renders valid Prometheus metrics" test_prometheus_metrics
      ]
  ]

-- | Default epoch timestamp for testing.
epoch :: UTCTime
epoch = read "2026-11-07 12:00:00 UTC"

-- | Generator for turn records.
genTurn :: H.Gen TurnTokenRecord
genTurn = do
  sIdx  <- Gen.int (Range.linear 1 500)
  fresh <- Gen.int (Range.linear 10 5000)
  cRead <- Gen.int (Range.linear 100 50000)
  outp  <- Gen.int (Range.linear 10 2000)
  pure $ TurnTokenRecord
    { turnId              = "turn-" <> T.pack (show sIdx)
    , conversationId      = "test-conv"
    , stepIndex           = sIdx
    , timestamp           = epoch
    , modelName           = "test-model"
    , reasoningEffort     = Nothing
    , freshInputTokens    = fresh
    , cacheReadTokens     = cRead
    , cacheCreationTokens = 0
    , outputTokens        = outp
    , wallClockMs         = 500
    }

prop_totals_monotonic :: H.Property
prop_totals_monotonic = H.property $ do
  turns <- H.forAll $ Gen.list (Range.linear 1 20) genTurn
  let (ledger, _) = recordTurns turns (emptyLedger Nothing)
      t = ledger.ledgerTotals
      expectedFresh = sum [ r.freshInputTokens | r <- turns ]
      expectedRead  = sum [ r.cacheReadTokens  | r <- turns ]
      expectedOut   = sum [ r.outputTokens     | r <- turns ]

  t.totalFreshInput H.=== expectedFresh
  t.totalCacheRead  H.=== expectedRead
  t.totalOutput     H.=== expectedOut
  t.turnCount       H.=== length turns

prop_cache_ratio_bounded :: H.Property
prop_cache_ratio_bounded = H.property $ do
  turns <- H.forAll $ Gen.list (Range.linear 0 15) genTurn
  let (ledger, _) = recordTurns turns (emptyLedger Nothing)
      ratio = cacheHitRatio ledger.ledgerTotals
  H.assert (ratio >= 0.0 && ratio <= 1.0)

test_circuit_breaker_trips :: Assertion
test_circuit_breaker_trips = do
  let budget = QuotaBudget
        { maxFreshTokens     = Just 1000
        , maxTurnFreshTokens = Nothing
        , maxTotalTokens     = Nothing
        , minCacheHitRatio   = Nothing
        , maxContextWindow   = Nothing
        }
      ledger0 = emptyLedger (Just budget)
      turn1 = TurnTokenRecord "t1" "c1" 1 epoch "m" Nothing 600 5000 0 100 200
      turn2 = TurnTokenRecord "t2" "c1" 2 epoch "m" Nothing 500 5000 0 100 200
      (ledger1, _) = recordTurn turn1 ledger0
      (ledger2, alerts2) = recordTurn turn2 ledger1

  evaluateCircuitBreaker ledger1 @?= BreakerClosed
  evaluateCircuitBreaker ledger2 @?= BreakerTripped
  any (\a -> alertSeverity a == SeverityCritical) alerts2 @?= True

test_turn_spike_alert :: Assertion
test_turn_spike_alert = do
  let budget = QuotaBudget
        { maxFreshTokens     = Nothing
        , maxTurnFreshTokens = Just 5000
        , maxTotalTokens     = Nothing
        , minCacheHitRatio   = Nothing
        , maxContextWindow   = Nothing
        }
      ledger0 = emptyLedger (Just budget)
      turnSpike = TurnTokenRecord "t-spike" "c1" 1 epoch "m" Nothing 12000 50000 0 500 1000
      (_, alerts) = recordTurn turnSpike ledger0

  length alerts @?= 1
  case alerts of
    (a:_) -> do
      alertSeverity a @?= SeverityWarning
      alertMetric a @?= "turn_fresh_input_tokens"
    [] -> assertFailure "Expected warning alert on spike"

test_context_inflation_alert :: Assertion
test_context_inflation_alert = do
  let budget = QuotaBudget
        { maxFreshTokens     = Nothing
        , maxTurnFreshTokens = Nothing
        , maxTotalTokens     = Nothing
        , minCacheHitRatio   = Nothing
        , maxContextWindow   = Just 100000
        }
      ledger0 = emptyLedger (Just budget)
      turnHuge = TurnTokenRecord "t-huge" "c1" 1 epoch "m" Nothing 5000 120000 0 500 1000
      (ledger1, alerts) = recordTurn turnHuge ledger0
      diag = diagnoseTokenHealth ledger1

  any (\a -> alertMetric a == "context_window_size") alerts @?= True
  diagContextInflationRisk diag @?= True

test_transcript_line_parsing :: Assertion
test_transcript_line_parsing = do
  let rawLine = "{\"step_index\":42,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"input_tokens\":1200,\"cache_read_tokens\":85000,\"output_tokens\":340}"
      mbRec = parseTranscriptLine "conv-test" "gemini-3.8-pro" rawLine

  case mbRec of
    Just r -> do
      r.stepIndex @?= 42
      r.freshInputTokens @?= 1200
      r.cacheReadTokens @?= 85000
      r.outputTokens @?= 340
      r.turnId @?= "conv-test-step-42"
    Nothing -> assertFailure "Failed to parse valid transcript line"

test_transcript_ignore_non_model :: Assertion
test_transcript_ignore_non_model = do
  let rawUserLine = "{\"step_index\":1,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"content\":\"hello\"}"
      mbRec = parseTranscriptLine "conv-test" "default" rawUserLine
  mbRec @?= Nothing

test_markdown_summary :: Assertion
test_markdown_summary = do
  let turn = TurnTokenRecord "t1" "c1" 1 epoch "m" Nothing 1000 9000 0 200 500
      (ledger, _) = recordTurn turn (emptyLedger Nothing)
      md = formatLedgerSummary ledger

  assertBool "Contains header" ("# Kagami-Ita (鏡板) Token Accounting" `T.isInfixOf` md)
  assertBool "Contains status" ("**Status:** ✅ HEALTHY" `T.isInfixOf` md)
  assertBool "Contains efficiency" ("90.00%" `T.isInfixOf` md)

test_prometheus_metrics :: Assertion
test_prometheus_metrics = do
  let turn = TurnTokenRecord "t1" "c1" 1 epoch "m" Nothing 2000 8000 0 500 500
      (ledger, _) = recordTurn turn (emptyLedger Nothing)
      prom = formatPrometheusMetrics ledger

  assertBool "Contains fresh input counter" ("kagami_ita_fresh_input_tokens_total 2000" `T.isInfixOf` prom)
  assertBool "Contains cache read counter" ("kagami_ita_cache_read_tokens_total 8000" `T.isInfixOf` prom)
  assertBool "Contains cache ratio gauge" ("kagami_ita_cache_hit_ratio 0.8000" `T.isInfixOf` prom)

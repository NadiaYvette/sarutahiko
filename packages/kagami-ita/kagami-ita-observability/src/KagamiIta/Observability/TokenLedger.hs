{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: KagamiIta.Observability.TokenLedger
-- Description: Pure Kagami-Ita token accounting ledger, caching efficiency, and quota alerts
--
-- Implements turn-level token breakdown, cumulative quota counters, prompt-cache
-- hit ratio computation, and circuit-breaker threshold evaluation.
module KagamiIta.Observability.TokenLedger
  ( -- * Core Data Types
    TurnTokenRecord(..)
  , TokenTotals(..)
  , QuotaBudget(..)
  , AlertSeverity(..)
  , QuotaAlert(..)
  , TokenLedger(..)

    -- * Construction & Ingestion
  , emptyLedger
  , emptyTotals
  , recordTurn
  , recordTurns

    -- * Analytics & Ratios
  , cacheHitRatio
  , turnCacheHitRatio
  , tokenBurnRatePerMinute
  , isQuotaExhausted
  , maxContextSizeSeen

    -- * Exposition & Formatting
  , formatLedgerSummary
  , formatPrometheusMetrics
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import GHC.Generics (Generic)
import Numeric (showFFloat)

-- | Detailed token expenditure recorded for a single interaction turn.
data TurnTokenRecord = TurnTokenRecord
  { turnId              :: !Text
  , conversationId      :: !Text
  , stepIndex           :: !Int
  , timestamp           :: !UTCTime
  , modelName           :: !Text
  , reasoningEffort     :: !(Maybe Text)
  , freshInputTokens    :: !Int
  , cacheReadTokens     :: !Int
  , cacheCreationTokens :: !Int
  , outputTokens        :: !Int
  , wallClockMs         :: !Int
  } deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cumulative token accounting totals aggregated across turns.
data TokenTotals = TokenTotals
  { totalFreshInput     :: !Int
  , totalCacheRead      :: !Int
  , totalCacheCreation  :: !Int
  , totalOutput         :: !Int
  , totalWallClockMs    :: !Int
  , turnCount           :: !Int
  } deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Static or dynamic limits configured to guard against runaway quota exhaustion.
data QuotaBudget = QuotaBudget
  { maxFreshTokens     :: !(Maybe Int)
  , maxTurnFreshTokens :: !(Maybe Int)
  , maxTotalTokens     :: !(Maybe Int)
  , minCacheHitRatio   :: !(Maybe Double)
  , maxContextWindow   :: !(Maybe Int)
  } deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Severity level for an observability alert.
data AlertSeverity
  = SeverityInfo
  | SeverityWarning
  | SeverityCritical
  deriving stock (Eq, Show, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | An alert raised when token usage exceeds configured thresholds or invariants.
data QuotaAlert = QuotaAlert
  { alertSeverity  :: !AlertSeverity
  , alertTurnId    :: !Text
  , alertMetric    :: !Text
  , alertMessage   :: !Text
  , alertThreshold :: !Double
  , alertActual    :: !Double
  } deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | The core Kagami-Ita token accounting ledger.
data TokenLedger = TokenLedger
  { ledgerBudget :: !(Maybe QuotaBudget)
  , ledgerTotals :: !TokenTotals
  , ledgerTurns  :: ![TurnTokenRecord]
  } deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Initialize an empty ledger with an optional budget.
emptyLedger :: Maybe QuotaBudget -> TokenLedger
emptyLedger mbBudget = TokenLedger
  { ledgerBudget = mbBudget
  , ledgerTotals = emptyTotals
  , ledgerTurns  = []
  }

-- | Zeroed token totals.
emptyTotals :: TokenTotals
emptyTotals = TokenTotals
  { totalFreshInput    = 0
  , totalCacheRead     = 0
  , totalCacheCreation = 0
  , totalOutput        = 0
  , totalWallClockMs   = 0
  , turnCount          = 0
  }

-- | Compute cache hit ratio for cumulative totals: cacheRead / (freshInput + cacheRead).
-- Returns 1.0 if no input tokens have been processed.
cacheHitRatio :: TokenTotals -> Double
cacheHitRatio totals =
  let denom = totals.totalFreshInput + totals.totalCacheRead
  in if denom == 0 then 1.0 else fromIntegral totals.totalCacheRead / fromIntegral denom

-- | Compute cache hit ratio for a single turn.
turnCacheHitRatio :: TurnTokenRecord -> Double
turnCacheHitRatio r =
  let denom = r.freshInputTokens + r.cacheReadTokens
  in if denom == 0 then 1.0 else fromIntegral r.cacheReadTokens / fromIntegral denom

-- | Compute average fresh input token burn rate per minute across recorded turns.
tokenBurnRatePerMinute :: TokenLedger -> Double
tokenBurnRatePerMinute ledger = case ledger.ledgerTurns of
  [] -> 0.0
  [single] ->
    let mins = max (fromIntegral single.wallClockMs / 60000.0) 0.001
    in fromIntegral single.freshInputTokens / mins
  (latest : rest) ->
    let oldest = last rest
        diffSeconds = realToFrac (diffUTCTime latest.timestamp oldest.timestamp) :: Double
        diffMinutes = max (diffSeconds / 60.0) 0.001
    in fromIntegral ledger.ledgerTotals.totalFreshInput / diffMinutes

-- | Check whether any critical quota limit has been breached.
isQuotaExhausted :: TokenLedger -> Bool
isQuotaExhausted ledger = case ledger.ledgerBudget of
  Nothing -> False
  Just b ->
    let freshExceeded = case b.maxFreshTokens of
          Nothing -> False
          Just maxF -> ledger.ledgerTotals.totalFreshInput >= maxF
        totalExceeded = case b.maxTotalTokens of
          Nothing -> False
          Just maxT -> (ledger.ledgerTotals.totalFreshInput + ledger.ledgerTotals.totalOutput) >= maxT
    in freshExceeded || totalExceeded

-- | Highest single context window size (freshInput + cacheRead) observed.
maxContextSizeSeen :: TokenLedger -> Int
maxContextSizeSeen ledger =
  case ledger.ledgerTurns of
    [] -> 0
    turns -> maximum [ t.freshInputTokens + t.cacheReadTokens | t <- turns ]

-- | Append a single turn record to the ledger, returning updated ledger and any alerts fired.
recordTurn :: TurnTokenRecord -> TokenLedger -> (TokenLedger, [QuotaAlert])
recordTurn turn ledger =
  let oldTotals = ledger.ledgerTotals
      newTotals = TokenTotals
        { totalFreshInput    = oldTotals.totalFreshInput + turn.freshInputTokens
        , totalCacheRead     = oldTotals.totalCacheRead + turn.cacheReadTokens
        , totalCacheCreation = oldTotals.totalCacheCreation + turn.cacheCreationTokens
        , totalOutput        = oldTotals.totalOutput + turn.outputTokens
        , totalWallClockMs   = oldTotals.totalWallClockMs + turn.wallClockMs
        , turnCount          = oldTotals.turnCount + 1
        }
      newTurns = turn : ledger.ledgerTurns
      newLedger = ledger { ledgerTotals = newTotals, ledgerTurns = newTurns }
      alerts = evaluateAlerts turn newTotals (ledger.ledgerBudget)
  in (newLedger, alerts)

-- | Append multiple turns in chronological sequence.
recordTurns :: [TurnTokenRecord] -> TokenLedger -> (TokenLedger, [QuotaAlert])
recordTurns [] ledger = (ledger, [])
recordTurns (t:ts) ledger =
  let (l1, a1) = recordTurn t ledger
      (l2, a2) = recordTurns ts l1
  in (l2, a1 ++ a2)

evaluateAlerts :: TurnTokenRecord -> TokenTotals -> Maybe QuotaBudget -> [QuotaAlert]
evaluateAlerts _ _ Nothing = []
evaluateAlerts turn totals (Just budget) =
  let a1 = case budget.maxTurnFreshTokens of
        Just limit | turn.freshInputTokens > limit ->
          [ QuotaAlert
              { alertSeverity  = SeverityWarning
              , alertTurnId    = turn.turnId
              , alertMetric    = "turn_fresh_input_tokens"
              , alertMessage   = "Single turn fresh input exceeded threshold (cache invalidation hazard)"
              , alertThreshold = fromIntegral limit
              , alertActual    = fromIntegral turn.freshInputTokens
              }
          ]
        _ -> []
      a2 = case budget.maxFreshTokens of
        Just limit | totals.totalFreshInput >= limit ->
          [ QuotaAlert
              { alertSeverity  = SeverityCritical
              , alertTurnId    = turn.turnId
              , alertMetric    = "cumulative_fresh_tokens"
              , alertMessage   = "Cumulative fresh token quota exhausted!"
              , alertThreshold = fromIntegral limit
              , alertActual    = fromIntegral totals.totalFreshInput
              }
          ]
        Just limit | fromIntegral totals.totalFreshInput >= (0.8 * fromIntegral limit :: Double) ->
          [ QuotaAlert
              { alertSeverity  = SeverityWarning
              , alertTurnId    = turn.turnId
              , alertMetric    = "cumulative_fresh_tokens"
              , alertMessage   = "Cumulative fresh token quota nearing exhaustion (>= 80%)"
              , alertThreshold = 0.8 * fromIntegral limit
              , alertActual    = fromIntegral totals.totalFreshInput
              }
          ]
        _ -> []
      a3 = case budget.minCacheHitRatio of
        Just minRatio | totals.turnCount >= 3 && cacheHitRatio totals < minRatio ->
          [ QuotaAlert
              { alertSeverity  = SeverityWarning
              , alertTurnId    = turn.turnId
              , alertMetric    = "cache_hit_ratio"
              , alertMessage   = "Prompt cache hit ratio degraded below efficiency minimum"
              , alertThreshold = minRatio
              , alertActual    = cacheHitRatio totals
              }
          ]
        _ -> []
      contextSize = turn.freshInputTokens + turn.cacheReadTokens
      a4 = case budget.maxContextWindow of
        Just maxCtx | contextSize > maxCtx ->
          [ QuotaAlert
              { alertSeverity  = SeverityWarning
              , alertTurnId    = turn.turnId
              , alertMetric    = "context_window_size"
              , alertMessage   = "Context window inflated beyond recommended compaction threshold"
              , alertThreshold = fromIntegral maxCtx
              , alertActual    = fromIntegral contextSize
              }
          ]
        _ -> []
  in a1 ++ a2 ++ a3 ++ a4

-- | Formats a comprehensive Markdown summary report of the token ledger.
formatLedgerSummary :: TokenLedger -> Text
formatLedgerSummary ledger =
  let t = ledger.ledgerTotals
      ratioPct = cacheHitRatio t * 100.0
      burn = tokenBurnRatePerMinute ledger
      maxCtx = maxContextSizeSeen ledger
      statusStr = if isQuotaExhausted ledger then "❌ EXHAUSTED" else "✅ HEALTHY"
  in T.unlines
    [ "# Kagami-Ita (鏡板) Token Accounting Ledger Summary"
    , ""
    , "- **Status:** " <> statusStr
    , "- **Total Interaction Turns:** " <> T.pack (show t.turnCount)
    , "- **Cumulative Fresh Input Tokens:** " <> T.pack (show t.totalFreshInput)
    , "- **Cumulative Cached Read Tokens:** " <> T.pack (show t.totalCacheRead)
    , "- **Cumulative Output Tokens:** " <> T.pack (show t.totalOutput)
    , "- **Prompt Cache Hit Efficiency:** " <> T.pack (showFFloat (Just 2) ratioPct "%")
    , "- **Peak Context Window Size:** " <> T.pack (show maxCtx) <> " tokens"
    , "- **Fresh Token Burn Rate:** " <> T.pack (showFFloat (Just 1) burn " tokens/min")
    , "- **Total Wall Clock Execution Time:** " <> T.pack (show (fromIntegral t.totalWallClockMs / 1000.0 :: Double)) <> "s"
    ]

-- | Formats Prometheus exposition metric text.
formatPrometheusMetrics :: TokenLedger -> Text
formatPrometheusMetrics ledger =
  let t = ledger.ledgerTotals
      ratio = cacheHitRatio t
  in T.unlines
    [ "# HELP kagami_ita_fresh_input_tokens_total Total un-cached fresh input tokens consumed"
    , "# TYPE kagami_ita_fresh_input_tokens_total counter"
    , "kagami_ita_fresh_input_tokens_total " <> T.pack (show t.totalFreshInput)
    , "# HELP kagami_ita_cache_read_tokens_total Total prompt-cache read tokens"
    , "# TYPE kagami_ita_cache_read_tokens_total counter"
    , "kagami_ita_cache_read_tokens_total " <> T.pack (show t.totalCacheRead)
    , "# HELP kagami_ita_output_tokens_total Total generated output tokens"
    , "# TYPE kagami_ita_output_tokens_total counter"
    , "kagami_ita_output_tokens_total " <> T.pack (show t.totalOutput)
    , "# HELP kagami_ita_cache_hit_ratio Current prompt-cache hit ratio"
    , "# TYPE kagami_ita_cache_hit_ratio gauge"
    , "kagami_ita_cache_hit_ratio " <> T.pack (showFFloat (Just 4) ratio "")
    , "# HELP kagami_ita_turn_count_total Total conversation turns recorded"
    , "# TYPE kagami_ita_turn_count_total counter"
    , "kagami_ita_turn_count_total " <> T.pack (show t.turnCount)
    ]

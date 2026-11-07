{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: KagamiIta.Observability.KagamiIta
-- Description: Kagami-Ita (鏡板) Observability Coordinator & Quota Circuit Breaker
--
-- Anchored in the Noh theatre metaphor: Kagami-Ita (鏡板) is the sacred pine
-- board reflecting all movement on the stage. This module coordinates token
-- telemetry, circuit-breaker tripping, context inflation diagnostics, and
-- remediation recommendations.
module KagamiIta.Observability.KagamiIta
  ( -- * Remediation & Diagnostics
    OperationalDiagnosis(..)
  , diagnoseTokenHealth
  , formatDiagnosisReport

    -- * Circuit Breaker
  , CircuitBreakerState(..)
  , evaluateCircuitBreaker
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showFFloat)

import KagamiIta.Observability.TokenLedger

-- | Diagnostic outcome with actionable recommendations for the orchestrator.
data OperationalDiagnosis = OperationalDiagnosis
  { diagHealthy                :: !Bool
  , diagContextInflationRisk   :: !Bool
  , diagCacheEfficiencyWarning :: !Bool
  , diagQuotaExhaustionRisk    :: !Bool
  , diagObservedPeakContext    :: !Int
  , diagObservedCacheHitRatio  :: !Double
  , diagActionRecommendations  :: ![Text]
  } deriving stock (Eq, Show)

-- | Current circuit breaker state.
data CircuitBreakerState
  = BreakerClosed   -- ^ Normal execution, within safe token limits.
  | BreakerTripped  -- ^ Quota limit exceeded; halt autonomous stepping.
  deriving stock (Eq, Show)

-- | Evaluates whether the circuit breaker should trip to protect API quota.
evaluateCircuitBreaker :: TokenLedger -> CircuitBreakerState
evaluateCircuitBreaker ledger
  | isQuotaExhausted ledger = BreakerTripped
  | otherwise = BreakerClosed

-- | Analyzes token ledger health and synthesizes strategic guidance.
diagnoseTokenHealth :: TokenLedger -> OperationalDiagnosis
diagnoseTokenHealth ledger =
  let t = ledger.ledgerTotals
      ratio = cacheHitRatio t
      maxCtx = maxContextSizeSeen ledger
      isExhausted = isQuotaExhausted ledger

      -- Heuristic thresholds
      contextInflated = maxCtx >= 100000
      cacheInefficient = t.turnCount >= 5 && ratio < 0.85
      quotaDanger = isExhausted || case ledger.ledgerBudget of
        Just b -> case b.maxFreshTokens of
          Just lim -> fromIntegral t.totalFreshInput >= (0.8 * fromIntegral lim :: Double)
          Nothing  -> False
        Nothing -> False

      recs = concat
        [ [ "⚠️ Context window is highly inflated (" <> T.pack (show maxCtx) <> " tokens). Execute `/compact` or offload historical state to Kioku/Kiroku."
          | contextInflated
          ]
        , [ "⚠️ Prompt cache hit ratio degraded to " <> T.pack (showFFloat (Just 1) (ratio * 100.0) "%") <> ". Ensure tool definitions and system prompt prefixes remain stable to preserve prompt cache."
          | cacheInefficient
          ]
        , [ "🛑 Token quota nearing exhaustion or exceeded. Suspend high-frequency autonomous polling loops."
          | quotaDanger
          ]
        , [ "💡 Turn count is high (" <> T.pack (show t.turnCount) <> " turns). Delegate sub-tasks to isolated leaf subagents to keep orchestrator context compact."
          | t.turnCount >= 100
          ]
        , [ "✅ Token usage is healthy and prompt cache efficiency is optimal."
          | not contextInflated && not cacheInefficient && not quotaDanger
          ]
        ]

      allHealthy = not contextInflated && not cacheInefficient && not quotaDanger

  in OperationalDiagnosis
       { diagHealthy                = allHealthy
       , diagContextInflationRisk   = contextInflated
       , diagCacheEfficiencyWarning = cacheInefficient
       , diagQuotaExhaustionRisk    = quotaDanger
       , diagObservedPeakContext    = maxCtx
       , diagObservedCacheHitRatio  = ratio
       , diagActionRecommendations  = recs
       }

-- | Formats diagnosis into a user-facing Markdown report.
formatDiagnosisReport :: OperationalDiagnosis -> Text
formatDiagnosisReport diag =
  let statusBadge = if diag.diagHealthy then "✅ STABLE" else "⚠️ ATTENTION REQUIRED"
      ratioPct = diag.diagObservedCacheHitRatio * 100.0
  in T.unlines
    [ "# Kagami-Ita (鏡板) Observability Health Report"
    , ""
    , "- **Operational Status:** " <> statusBadge
    , "- **Peak Context Window Size:** " <> T.pack (show diag.diagObservedPeakContext) <> " tokens"
    , "- **Prompt Cache Hit Efficiency:** " <> T.pack (showFFloat (Just 2) ratioPct "%")
    , ""
    , "## Actionable Recommendations"
    , ""
    ] <> T.unlines [ "- " <> r | r <- diag.diagActionRecommendations ]

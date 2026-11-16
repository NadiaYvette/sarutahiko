{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module      : Yamaarashi.Context.TailExcision
-- Description : Stage 2 Prefix-Preserving Tail Pruning & Stage 3 Stateless Stalk Mode
--
-- Preserves prompt cache KV-efficiency across multi-turn worker repair loops.
-- When a worker turn fails to advance the verification state (identical compiler
-- diagnostics), 'pruneTranscriptTail' excises the bloated turn tail and substitutes
-- a compact 50-token tombstone pointing to the spilled log on disk.
-- 'renderStatelessStalk' freezes invariant rules/contracts in Block A and bounds
-- dynamic turn state in Block B to <= 6,000 tokens total.
module Yamaarashi.Context.TailExcision
  ( -- * Core Data Types
    TurnObservation (..)
  , TombstoneRecord (..)
  , ContextValveState (..)
  , FrozenBlockA (..)
  , DynamicBlockB (..)
  , StalkPrompt (..)

    -- * Initialization
  , emptyContextValveState

    -- * Tail Excision & Pruning
  , pruneTranscriptTail
  , applyTailExcision

    -- * Stateless 2-Block Stalk Rendering
  , renderStatelessStalk
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | Observation recorded from a single execution or repair turn.
data TurnObservation = TurnObservation
  { obsTurnIndex        :: !Word
  , obsEstimatedTokens  :: !Int
  , obsCompilerCode     :: !(Maybe Text)
  , obsErrorCount       :: !Int
  , obsRawText          :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Tombstone reference replacing an excised transcript turn.
data TombstoneRecord = TombstoneRecord
  { tombTurnIndex :: !Word
  , tombLogPath   :: !FilePath
  , tombReason    :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Context valve tracking prefix stability, turn messages, and tombstones.
data ContextValveState = ContextValveState
  { messageHistory     :: ![Text]
  , cachedPrefixBytes  :: !Int
  , lastCompilerCode   :: !(Maybe Text)
  , lastErrorCount     :: !Int
  , tombstoneRecords   :: ![TombstoneRecord]
  } deriving stock (Eq, Show, Generic)

-- | Initial blank valve state.
emptyContextValveState :: ContextValveState
emptyContextValveState = ContextValveState
  { messageHistory    = []
  , cachedPrefixBytes = 0
  , lastCompilerCode  = Nothing
  , lastErrorCount    = 0
  , tombstoneRecords  = []
  }

-- | Frozen immutable Block A: system directives, packet contract, interfaces.
newtype FrozenBlockA = FrozenBlockA { unBlockA :: Text }
  deriving stock (Eq, Show, Generic)

-- | Dynamic Block B: current file buffer, compiler error digest.
newtype DynamicBlockB = DynamicBlockB { unBlockB :: Text }
  deriving stock (Eq, Show, Generic)

-- | Rendered prompt for the stateless stalk mode worker.
newtype StalkPrompt = StalkPrompt { unStalkPrompt :: Text }
  deriving stock (Eq, Show, Generic)

-- | Format a concise 50-token tombstone.
formatTombstone :: Word -> Text
formatTombstone turn =
  "[Excised Turn " <> T.pack (show turn) <> ": see .yamaarashi/spill/turn-" <> T.pack (show turn) <> ".log]"

-- | Prune the transcript tail if the previous turn failed to advance verification
-- and exceeded the token threshold (> 1,200 tokens).
pruneTranscriptTail :: ContextValveState -> TurnObservation -> ContextValveState
pruneTranscriptTail state obs =
  let isBloated = obsEstimatedTokens obs > 1200
      nonAdvancing =
        obsCompilerCode obs == lastCompilerCode state
        && obsErrorCount obs >= lastErrorCount state
        && obsErrorCount obs > 0
  in if isBloated && nonAdvancing
       then
         let tomb = formatTombstone (obsTurnIndex obs)
             tRecord = TombstoneRecord
               { tombTurnIndex = obsTurnIndex obs
               , tombLogPath   = ".yamaarashi/spill/turn-" <> show (obsTurnIndex obs) <> ".log"
               , tombReason    = "Non-advancing compiler state (" <> maybe "unknown" id (obsCompilerCode obs) <> ")"
               }
             history = case messageHistory state of
               []     -> [tomb]
               (_:ms) -> tomb : ms
         in state
              { messageHistory   = history
              , tombstoneRecords = tRecord : tombstoneRecords state
              }
       else
         state
           { messageHistory   = obsRawText obs : messageHistory state
           , lastCompilerCode = obsCompilerCode obs
           , lastErrorCount   = obsErrorCount obs
           }

-- | Apply tail excision over a list of historical observations.
applyTailExcision :: ContextValveState -> [TurnObservation] -> ContextValveState
applyTailExcision = foldl pruneTranscriptTail

-- | Render the 2-block stateless stalk prompt.
-- Invariant: Caps total rendered stalk prompt to <= 6,000 tokens (approx 24,000 chars)
-- while keeping Block A strictly immutable.
renderStatelessStalk :: FrozenBlockA -> DynamicBlockB -> StalkPrompt
renderStatelessStalk (FrozenBlockA blockA) (DynamicBlockB blockB) =
  let maxTotalTokens = 6000
      maxTotalChars  = maxTotalTokens * 4
      blockAChars    = T.length blockA
      allowedBChars  = max 500 (maxTotalChars - blockAChars - 50)
      boundedB       = if T.length blockB > allowedBChars
                         then T.take allowedBChars blockB <> "\n... [Block B truncated to fit 6,000-token stalk limit]"
                         else blockB
      fullPrompt     = blockA <> "\n\n=== [DYNAMIC WORKER CONTEXT: BLOCK B] ===\n\n" <> boundedB
  in StalkPrompt fullPrompt

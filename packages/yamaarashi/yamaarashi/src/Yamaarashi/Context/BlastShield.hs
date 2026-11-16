{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module      : Yamaarashi.Context.BlastShield
-- Description : Stage 1 Pre-Ingestion Tool Output Spill & GHC Digest Filter
--
-- Intercepts voluminous tool outputs (such as compiler and test suite logs)
-- before they reach the language model context buffer. If an output exceeds
-- 'maxToolOutputTokens', the full transcript is spilled to disk and replaced
-- with a compact, structured diagnostic digest (< 300 tokens) highlighting
-- error codes, source locations, and failure traces.
module Yamaarashi.Context.BlastShield
  ( -- * Configuration
    BlastShieldConfig (..)
  , defaultBlastShieldConfig

    -- * Results
  , SpillResult (..)

    -- * Core Operations
  , spillOrDigest
  , extractDiagnostics
  , truncateCompilerOutput
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | Configuration governing the BlastShield pre-ingestion valve.
data BlastShieldConfig = BlastShieldConfig
  { maxToolOutputTokens :: !Int
  , spillDir            :: !FilePath
  , maxDigestTokens     :: !Int
  } deriving stock (Eq, Show, Generic)

-- | Default configuration:
-- * 'maxToolOutputTokens': 1500 tokens (~6,000 chars)
-- * 'spillDir': @.yamaarashi/spill@
-- * 'maxDigestTokens': 300 tokens (~1,200 chars)
defaultBlastShieldConfig :: BlastShieldConfig
defaultBlastShieldConfig = BlastShieldConfig
  { maxToolOutputTokens = 1500
  , spillDir            = ".yamaarashi/spill"
  , maxDigestTokens     = 300
  }

-- | Outcome of passing output through the blast shield.
data SpillResult
  = InlineOutput !Text
  | SpilledWithDigest
      { spillPath :: !FilePath
      , digest    :: !Text
      }
  deriving stock (Eq, Show, Generic)

-- | Estimate token count for a text snippet using standard 4 chars/token heuristic.
estimateTokens :: Text -> Int
estimateTokens txt = (T.length txt + 3) `div` 4

-- | Intercept raw tool output. If the text token estimate is within budget,
-- return 'InlineOutput'. Otherwise, spill the raw output to disk and produce
-- a compact diagnostic summary.
spillOrDigest :: BlastShieldConfig -> Word -> Text -> IO SpillResult
spillOrDigest cfg turn rawText = do
  let tokens = estimateTokens rawText
  if tokens <= maxToolOutputTokens cfg
    then pure (InlineOutput rawText)
    else do
      createDirectoryIfMissing True (spillDir cfg)
      let logFileName = "turn-" <> show turn <> ".log"
          outPath = spillDir cfg </> logFileName
      TIO.writeFile outPath rawText
      let diag = extractDiagnostics (maxDigestTokens cfg) rawText
          header = "[BlastShield] Output exceeded " <> T.pack (show (maxToolOutputTokens cfg))
                <> " tokens (" <> T.pack (show tokens) <> " estimated). Spilled to "
                <> T.pack outPath <> "\n"
          summary = header <> diag
      pure (SpilledWithDigest outPath summary)

-- | Truncate raw compiler output down to a bounded size, highlighting error spans.
truncateCompilerOutput :: Text -> Text
truncateCompilerOutput raw =
  let cfg = defaultBlastShieldConfig
  in if estimateTokens raw <= maxDigestTokens cfg
       then raw
       else extractDiagnostics (maxDigestTokens cfg) raw

-- | Extract structured GHC diagnostic spans (file:line:col), GHC error codes (GHC-xxxxx),
-- and test failure headers into a compact digest capped at approximately maxTokens.
extractDiagnostics :: Int -> Text -> Text
extractDiagnostics maxTokens raw =
  let lns = T.lines raw
      isDiagLine l =
        "error:" `T.isInfixOf` l
        || "error [" `T.isInfixOf` l
        || "GHC-" `T.isInfixOf` l
        || "FAIL" `T.isInfixOf` l
        || "Failed" `T.isInfixOf` l
        || "failed:" `T.isInfixOf` l
        || isLocation l
      isLocation l = case T.splitOn ":" l of
        (_file : line : col : _) ->
          not (T.null line) && T.all isDigit line && not (T.null col) && T.all isDigit (T.takeWhile isDigit col)
        _ -> False
      relevant = filter isDiagLine lns
      chosenLines = if null relevant then take 20 lns else take 30 relevant
      candidate = T.unlines chosenLines
      maxChars = maxTokens * 4
  in if T.length candidate <= maxChars
       then candidate
       else T.take maxChars candidate <> "\n... [digest truncated to token ceiling]"

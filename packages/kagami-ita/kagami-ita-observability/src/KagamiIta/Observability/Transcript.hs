{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module: KagamiIta.Observability.Transcript
-- Description: Ingestion of JSONL conversation transcripts into Kagami-Ita token accounting
--
-- Parses line-delimited transcript JSON records containing token metrics
-- (fresh input tokens, cache read tokens, cache creation tokens, and output tokens)
-- and folds them into the token ledger.
module KagamiIta.Observability.Transcript
  ( parseTranscriptLine
  , parseTranscriptLines
  , ingestTranscriptContent
  , ingestTranscriptFile
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson ((.:?), (.:), FromJSON(..), withObject)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)

import KagamiIta.Observability.TokenLedger

data RawTranscriptStep = RawTranscriptStep
  { rawStepIndex           :: !Int
  , rawCreatedAt           :: !(Maybe Text)
  , rawSource              :: !(Maybe Text)
  , rawInputTokens         :: !(Maybe Int)
  , rawCacheReadTokens     :: !(Maybe Int)
  , rawCacheCreationTokens :: !(Maybe Int)
  , rawOutputTokens        :: !(Maybe Int)
  , rawModel               :: !(Maybe Text)
  } deriving stock (Eq, Show)

instance FromJSON RawTranscriptStep where
  parseJSON = withObject "TranscriptStep" $ \o -> do
    sIdx  <- o .: "step_index"
    cAt   <- o .:? "created_at"
    src   <- o .:? "source"
    inp   <- o .:? "input_tokens"
    cRead <- o .:? "cache_read_tokens"
    cCre  <- o .:? "cache_creation_tokens"
    outp  <- o .:? "output_tokens"
    mdl   <- o .:? "model"
    pure $ RawTranscriptStep
      { rawStepIndex           = sIdx
      , rawCreatedAt           = cAt
      , rawSource              = src
      , rawInputTokens         = inp
      , rawCacheReadTokens     = cRead
      , rawCacheCreationTokens = cCre
      , rawOutputTokens        = outp
      , rawModel               = mdl
      }

-- | Fallback epoch timestamp for steps lacking created_at.
epochTimestamp :: UTCTime
epochTimestamp = read "1970-01-01 00:00:00 UTC"

-- | Parse a single JSON line from a transcript. Returns 'Just' 'TurnTokenRecord'
-- if the line represents a model interaction turn with token metrics.
parseTranscriptLine :: Text -> Text -> Text -> Maybe TurnTokenRecord
parseTranscriptLine convId defaultModel lineTxt
  | T.null (T.strip lineTxt) = Nothing
  | otherwise =
      case Aeson.decodeStrict (TE.encodeUtf8 lineTxt) of
        Just (raw :: RawTranscriptStep)
          | raw.rawSource == Just "MODEL" || raw.rawInputTokens /= Nothing ->
              let fresh = fromMaybe 0 raw.rawInputTokens
                  cRead = fromMaybe 0 raw.rawCacheReadTokens
                  cCre  = fromMaybe 0 raw.rawCacheCreationTokens
                  outp  = fromMaybe 0 raw.rawOutputTokens
                  ts    = case raw.rawCreatedAt of
                    Just s  -> fromMaybe epochTimestamp (iso8601ParseM (T.unpack s))
                    Nothing -> epochTimestamp
                  mdl   = fromMaybe defaultModel raw.rawModel
                  tId   = convId <> "-step-" <> T.pack (show raw.rawStepIndex)
              in Just $ TurnTokenRecord
                   { turnId              = tId
                   , conversationId      = convId
                   , stepIndex           = raw.rawStepIndex
                   , timestamp           = ts
                   , modelName           = mdl
                   , reasoningEffort     = Nothing
                   , freshInputTokens    = fresh
                   , cacheReadTokens     = cRead
                   , cacheCreationTokens = cCre
                   , outputTokens        = outp
                   , wallClockMs         = 0
                   }
          | otherwise -> Nothing
        Nothing -> Nothing

-- | Parse all lines from transcript JSONL content.
parseTranscriptLines :: Text -> Text -> Text -> [TurnTokenRecord]
parseTranscriptLines convId defaultModel content =
  mapMaybe (parseTranscriptLine convId defaultModel) (T.lines content)

-- | Ingest transcript text directly into a TokenLedger.
ingestTranscriptContent :: Text -> Text -> Text -> TokenLedger -> (TokenLedger, [QuotaAlert])
ingestTranscriptContent convId defaultModel content ledger =
  let records = parseTranscriptLines convId defaultModel content
  in recordTurns records ledger

-- | Ingest a transcript file from disk into a TokenLedger.
ingestTranscriptFile :: Text -> Text -> FilePath -> TokenLedger -> IO (Either Text (TokenLedger, [QuotaAlert]))
ingestTranscriptFile convId defaultModel path ledger = do
  res <- try @SomeException (BS.readFile path)
  case res of
    Left ex -> pure $ Left (T.pack (show ex))
    Right bytes ->
      let content = TE.decodeUtf8Lenient bytes
      in pure $ Right (ingestTranscriptContent convId defaultModel content ledger)

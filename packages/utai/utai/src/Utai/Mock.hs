{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Utai.Mock
-- Description : Deterministic mock interpreter and fixture store for ModelAPI
--
-- Implements the canonical 'utai-mock' carrier satisfying laws L1–L4 per
-- LLM_SUBSTRATE_DESIGN.md. Provides zero-token, hermetic model execution
-- for tests and autonomous task loops.
module Utai.Mock
  ( -- * Fixtures
    FixtureRule (..)
  , FixtureStore (..)
  , emptyFixtureStore
  , addFixture
  , cannedText
  , cannedToolCall

    -- * Pure Operations (Laws L1–L4)
  , runMockCompletion
  , runMockStream
  , runMockEmbed
  , runMockCount

    -- * Tagless Carrier
  , MockModelT (..)
  , runMockModelT

    -- * Effectful Carrier
  , runModelAPIMock
  ) where

import Control.Applicative (Alternative)
import Control.Monad (MonadPlus)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Reader (ReaderT (..), ask)
import Data.ByteString (ByteString)
import qualified Data.List as List
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Generics (Generic)

import Sarutahiko.Effect.ModelAPI
import Sarutahiko.Effect.Stepper (Stepper, unfoldStepper)
import Utai.Capability (MonadModelAPI (..))

-- | A deterministic fixture rule matching request prompt prefixes.
data FixtureRule = FixtureRule
  { rulePrefix       :: !Text
  , ruleResponse     :: !CompletionResp
  , ruleStreamChunks :: ![Text]
  } deriving stock (Eq, Show, Generic)

-- | Store of configured deterministic fixture rules.
newtype FixtureStore = FixtureStore
  { unFixtureStore :: [FixtureRule]
  } deriving stock (Eq, Show, Generic)

-- | An empty fixture store.
emptyFixtureStore :: FixtureStore
emptyFixtureStore = FixtureStore []

-- | Add a rule to the fixture store (higher priority rules first).
addFixture :: FixtureRule -> FixtureStore -> FixtureStore
addFixture r (FixtureStore rs) = FixtureStore (r : rs)

-- | Helper to construct a canned text response fixture.
cannedText :: Text -> Text -> FixtureRule
cannedText prefix answer = FixtureRule
  { rulePrefix       = prefix
  , ruleResponse     = CompletionResp
      { respContent    = answer
      , respToolCalls  = []
      , respStopReason = StopCompleted
      , respUsage      = Usage (T.length prefix) (T.length answer) 0 0 0
      }
  , ruleStreamChunks = [answer]
  }

-- | Helper to construct a canned tool-call response fixture.
cannedToolCall :: Text -> Text -> Text -> ByteString -> FixtureRule
cannedToolCall prefix cid cname cargs = FixtureRule
  { rulePrefix       = prefix
  , ruleResponse     = CompletionResp
      { respContent    = ""
      , respToolCalls  = [ToolCall cid cname cargs]
      , respStopReason = StopToolUse
      , respUsage      = Usage (T.length prefix) 20 0 0 0
      }
  , ruleStreamChunks = []
  }

-- | Extract the combined prompt text from a completion request.
promptFromReq :: CompletionReq -> Text
promptFromReq req = T.intercalate "\n" [ msgContent m | m <- reqMessages req ]

-- | Match a completion request against the fixture store.
findMatchingRule :: FixtureStore -> CompletionReq -> Maybe FixtureRule
findMatchingRule (FixtureStore rules) req =
  let prompt = promptFromReq req
  in List.find (\r -> rulePrefix r `T.isPrefixOf` prompt) rules

-- | Pure completion execution enforcing Option Honesty (L3).
runMockCompletion :: FixtureStore -> CompletionReq -> Either Text CompletionResp
runMockCompletion store req = do
  -- Validate Law L3: Option Honesty
  case optTemperature (reqOptions req) of
    Just t | t < 0.0 -> Left "Option Honesty Violation: negative temperature is unsupported"
    _                -> Right ()

  case findMatchingRule store req of
    Just r -> Right (ruleResponse r)
    Nothing ->
      let prompt = promptFromReq req
          mockContent = "Mock response to: " <> prompt
      in Right CompletionResp
        { respContent    = mockContent
        , respToolCalls  = []
        , respStopReason = StopCompleted
        , respUsage      = Usage (T.length prompt) (T.length mockContent) 0 0 0
        }

-- | Pure streaming execution enforcing Terminator Honesty (L1) and Option Honesty (L3).
runMockStream :: Applicative m => FixtureStore -> CompletionReq -> Stepper m StreamEvent
runMockStream store req =
  case runMockCompletion store req of
    Left err -> unfoldStepper [EventStart, EventError err]
    Right resp ->
      let mRule = findMatchingRule store req
          chunks = case mRule of
            Just r  -> ruleStreamChunks r
            Nothing -> [respContent resp]
          events = [EventStart]
                ++ map TextDelta chunks
                ++ [EventDone (respUsage resp) (respStopReason resp)]
      in unfoldStepper events

-- | Pure embeddings execution.
runMockEmbed :: FixtureStore -> EmbedReq -> Either Text EmbedResp
runMockEmbed _ req =
  let count = length (embedTexts req)
      vectors = replicate count [0.1, 0.2, 0.3]
      usage = Usage (count * 5) 0 0 0 0
  in Right EmbedResp
    { embedVectors = vectors
    , embedUsage   = usage
    }

-- | Pure token count estimation.
runMockCount :: [Message] -> TokenCount
runMockCount msgs =
  let totalChars = sum [ T.length (msgContent m) | m <- msgs ]
  in TokenCount (max 1 (totalChars `div` 4))

-- | Tagless-final monad transformer carrier for 'MonadModelAPI'.
newtype MockModelT m a = MockModelT
  { unMockModelT :: ReaderT FixtureStore m a
  } deriving newtype
      ( Functor
      , Applicative
      , Monad
      , MonadIO
      , Alternative
      , MonadPlus
      )

-- | Run a 'MockModelT' computation against a 'FixtureStore'.
runMockModelT :: FixtureStore -> MockModelT m a -> m a
runMockModelT store (MockModelT m) = runReaderT m store

instance Monad m => MonadModelAPI (MockModelT m) where
  complete req = MockModelT $ do
    store <- ask
    case runMockCompletion store req of
      Left err  -> pure $ CompletionResp "" [] (StopError err) mempty
      Right res -> pure res
  stream req = MockModelT $ do
    store <- ask
    pure (runMockStream store req)
  embed req = MockModelT $ do
    store <- ask
    case runMockEmbed store req of
      Left _    -> pure $ EmbedResp [] mempty
      Right res -> pure res
  countTokens msgs = pure (runMockCount msgs)

-- | Effectful carrier interpreting 'ModelAPI' using deterministic mock fixtures.
runModelAPIMock :: FixtureStore -> Eff (ModelAPI : es) a -> Eff es a
runModelAPIMock store = interpret $ \_ -> \case
  Complete req -> case runMockCompletion store req of
    Left err  -> pure $ CompletionResp "" [] (StopError err) mempty
    Right res -> pure res
  Stream req   -> pure $ runMockStream store req
  Embed req    -> case runMockEmbed store req of
    Left _    -> pure $ EmbedResp [] mempty
    Right res -> pure res
  Count msgs   -> pure $ runMockCount msgs

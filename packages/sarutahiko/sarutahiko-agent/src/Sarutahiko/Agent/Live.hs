{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Agent.Live
-- Description : Production live ModelAPI interpreter for autonomous agent execution
--
-- Direct, zero-dependency model execution utilizing Utai with deterministic
-- provider fallback cascades (OmniRoute -> OpenCode) and hard fail-closed timeouts.
--
-- === Intellectual Lineage & Attribution
-- * Utai substrate (Nadeem Bitar / baikai) — provider laws L1-L4 and model abstraction
-- * Hermes Agent (Nous Research) — prompt-cache preservation and turn streaming
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Agent.Live
  ( -- * Live ModelAPI Carriers
    runModelAPILive
  , runModelAPILiveWithProfiles
  , defaultLiveProfiles
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret)

import Sarutahiko.Effect.ModelAPI
import Sarutahiko.Effect.Stepper (unfoldStepper)
import Utai
  ( ProviderProfile (..)
  , callOpenAIWithFallback
  , omnirouteProfile
  , opencodeProfile
  )

-- | Construct default provider fallback profiles for a given model.
defaultLiveProfiles :: Text -> [ProviderProfile]
defaultLiveProfiles model =
  [ omnirouteProfile { profileModels = [model] }
  , opencodeProfile
  ]

-- | Production Effectful carrier interpreting 'ModelAPI' using the default fallback profiles.
runModelAPILive
  :: (IOE :> es)
  => Text
  -> Eff (ModelAPI : es) a
  -> Eff es a
runModelAPILive model = runModelAPILiveWithProfiles (defaultLiveProfiles model)

-- | Production Effectful carrier interpreting 'ModelAPI' over specified fallback profiles.
runModelAPILiveWithProfiles
  :: (IOE :> es)
  => [ProviderProfile]
  -> Eff (ModelAPI : es) a
  -> Eff es a
runModelAPILiveWithProfiles profiles = interpret $ \_ -> \case
  Complete req -> do
    res <- liftIO $ callOpenAIWithFallback profiles req
    case res of
      Left err   -> pure $ CompletionResp "" [] (StopError err) mempty
      Right resp -> pure resp
  Stream req -> do
    res <- liftIO $ callOpenAIWithFallback profiles req
    case res of
      Left err -> pure $ unfoldStepper [EventStart, EventError err]
      Right resp ->
        let events = [EventStart, TextDelta (respContent resp), EventDone (respUsage resp) (respStopReason resp)]
        in pure (unfoldStepper events)
  Embed _ ->
    pure $ EmbedResp [] mempty
  Count msgs -> do
    let totalChars = sum [ T.length (msgContent m) | m <- msgs ]
    pure $ TokenCount (max 1 (totalChars `div` 4))

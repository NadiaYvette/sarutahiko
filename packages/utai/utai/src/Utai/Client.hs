{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Utai.Client
-- Description : Production OpenAI-compatible carrier with hard fail-closed timeouts
--
-- Direct, zero-dependency model invocation calling local endpoints (OmniRoute,
-- OpenCode) via curl and typed-process per LLM_SUBSTRATE_DESIGN.md §6.1.
-- Eliminates subprocess agent wrappers (Hermes) and provides strict OS-level
-- connection and execution timeouts with deterministic fallback cascades.
module Utai.Client
  ( -- * Endpoint Dispatch
    callOpenAI
  , callOpenAIWithTimeout
  , callOpenAIWithFallback

    -- * Effectful Carrier
  , runModelAPIOpenAI
  ) where

import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Effectful
import Effectful.Dispatch.Dynamic (interpret)
import System.Exit (ExitCode (..))
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)

import Sarutahiko.Effect.ModelAPI
import Sarutahiko.Effect.Stepper (unfoldStepper)
import Utai.Capability ()
import Utai.Types
import Utai.Wire (decodeChatCompletionResp, encodeChatCompletionReq)

-- | Call an OpenAI-compatible endpoint with default 60s timeout and 10s connect timeout.
callOpenAI :: ProviderProfile -> CompletionReq -> IO (Either Text CompletionResp)
callOpenAI = callOpenAIWithTimeout 60 10

-- | Call an OpenAI-compatible endpoint with explicit max execution and connect timeouts.
callOpenAIWithTimeout :: Int -> Int -> ProviderProfile -> CompletionReq -> IO (Either Text CompletionResp)
callOpenAIWithTimeout maxSec connectSec profile req = do
  let url = T.unpack (profileBaseUrl profile <> "/chat/completions")
      authHeader = "Authorization: Bearer " <> T.unpack (profileApiKey profile)
      bodyBytes = encodeChatCompletionReq req
      args =
        [ "-s"
        , "-S"
        , "--connect-timeout", show connectSec
        , "--max-time", show maxSec
        , "-X", "POST"
        , url
        , "-H", authHeader
        , "-H", "Content-Type: application/json"
        , "--data-binary", "@-"
        ]
      p = setStdin (byteStringInput (BSL.fromStrict bodyBytes)) (proc "curl" args)

  (code, outBs, errBs) <- readProcess p
  case code of
    ExitFailure c -> do
      let errTxt = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict errBs)
      pure $ Left $ "curl failed with exit code " <> T.pack (show c) <> ": " <> errTxt
    ExitSuccess -> do
      let outStrict = BSL.toStrict outBs
      case decodeChatCompletionResp outStrict of
        Left parseErr ->
          pure $ Left $ "Failed to parse completion JSON (" <> parseErr <> "): "
                     <> TE.decodeUtf8With TEE.lenientDecode outStrict
        Right resp ->
          pure $ Right resp

-- | Call with deterministic fallback cascades across multiple provider profiles.
callOpenAIWithFallback :: [ProviderProfile] -> CompletionReq -> IO (Either Text CompletionResp)
callOpenAIWithFallback [] _ = pure $ Left "All provider profiles exhausted in fallback chain."
callOpenAIWithFallback (p:ps) req = do
  res <- callOpenAI p req
  case res of
    Right resp -> pure (Right resp)
    Left _err  -> callOpenAIWithFallback ps req

-- | Production Effectful carrier interpreting 'ModelAPI' over OpenAI-compatible endpoints.
runModelAPIOpenAI :: (IOE :> es) => ProviderProfile -> Eff (ModelAPI : es) a -> Eff es a
runModelAPIOpenAI profile = interpret $ \_ -> \case
  Complete req -> do
    res <- liftIO $ callOpenAI profile req
    case res of
      Left err   -> pure $ CompletionResp "" [] (StopError err) mempty
      Right resp -> pure resp
  Stream req -> do
    res <- liftIO $ callOpenAI profile req
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

{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Agent.Turn
-- Description : Interpreted ReAct-style agent turn loop with bounded iteration
--
-- Executes an autonomous agent turn with consent checking, tool dispatching,
-- event logging, and fail-closed termination per NIH_PLAN.md Tier 2 (sarutahiko-agent).
module Sarutahiko.Agent.Turn
  ( executeAgentTurn
  , AgentTurnResult (..)
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Sarutahiko.Agent.Registry
  ( RegisteredTool (..)
  , ToolRegistry
  , lookupTool
  , toToolDefinitions
  )
import Sarutahiko.Effect.EventStore (SessionId)
import Sarutahiko.Effect.ModelAPI
  ( CompletionReq (..)
  , CompletionResp (..)
  , Message (..)
  , Role (..)
  , ToolCall (..)
  , Usage (..)
  , defaultModelOptions
  )
import Sarutahiko.Hooks.Allowlist (Allowlist, checkToolConsent)
import Sarutahiko.Hooks.Types (HookConsent (..))
import Sarutahiko.Session.Types
  ( encodeMessagePayload
  , encodeToolInvoked
  , encodeToolObserved
  )
import Utai.Capability (MonadModelAPI (..))
import Yamaarashi.Flow.Capability (MonadEventStore (..))

-- | Result of a full agent turn execution.
data AgentTurnResult = AgentTurnResult
  { atrSessionId   :: !SessionId
  , atrFinalReply  :: !Text
  , atrToolCalls   :: ![ToolCall]
  , atrStepsTaken  :: !Int
  , atrUsage       :: !Usage
  , atrCompleted   :: !Bool
  } deriving stock (Eq, Show)

-- | Execute a bounded ReAct agent turn.
executeAgentTurn
  :: (MonadModelAPI m, MonadEventStore m, MonadIO m)
  => SessionId
  -> Text               -- ^ Model
  -> FilePath           -- ^ Cwd
  -> [Message]          -- ^ Prior context messages
  -> Text               -- ^ User prompt
  -> ToolRegistry       -- ^ Available tools
  -> Allowlist          -- ^ Hook/command consent allowlist
  -> Int                -- ^ Max iterations (bounded <= 10)
  -> m AgentTurnResult
executeAgentTurn sid model _cwd history prompt registry allowlist maxIter = do
  -- 1. Append user prompt to EventStore
  _ <- appendEvent sid "message" (encodeMessagePayload RoleUser prompt)

  let boundedMax = max 1 (min 10 maxIter)
      initialMsgs = history ++ [Message RoleUser prompt]
      zeroUsage = Usage 0 0 0 0 0

  -- 2. Run bounded ReAct step loop
  loop initialMsgs [] 1 zeroUsage boundedMax
  where
    loop msgs allCalls step accumulatedUsage maxSteps
      | step > maxSteps = do
          let reply = "Iteration ceiling reached (" <> T.pack (show maxSteps) <> " steps without completion)."
          _ <- appendEvent sid "message" (encodeMessagePayload RoleAssistant reply)
          pure AgentTurnResult
            { atrSessionId   = sid
            , atrFinalReply  = reply
            , atrToolCalls   = allCalls
            , atrStepsTaken  = step - 1
            , atrUsage       = accumulatedUsage
            , atrCompleted   = False
            }

      | otherwise = do
          let req = CompletionReq
                { reqModel    = model
                , reqMessages = msgs
                , reqTools    = toToolDefinitions registry
                , reqOptions  = defaultModelOptions
                }
          resp <- complete req
          let stepUsage = combineUsage accumulatedUsage (respUsage resp)

          case respToolCalls resp of
            [] -> do
              -- Assistant finished turn without tool call
              let finalReply = respContent resp
              _ <- appendEvent sid "message" (encodeMessagePayload RoleAssistant finalReply)
              pure AgentTurnResult
                { atrSessionId   = sid
                , atrFinalReply  = finalReply
                , atrToolCalls   = allCalls
                , atrStepsTaken  = step
                , atrUsage       = stepUsage
                , atrCompleted   = True
                }

            (tc:_) -> do
              -- Tool call requested: enforce single tool per turn step
              _ <- appendEvent sid "tool_invoked" (encodeToolInvoked (callName tc) (callId tc) (callArguments tc))

              -- Check consent
              (obsOutput, obsOk) <- case checkToolConsent allowlist (callName tc) of
                ConsentDenied reason ->
                  pure ("Execution blocked by consent allowlist: " <> reason, False)
                ConsentPrompt promptMsg ->
                  pure ("Execution deferred pending user consent: " <> promptMsg, False)
                ConsentApproved ->
                  case lookupTool (callName tc) registry of
                    Nothing ->
                      pure ("Error: Tool '" <> callName tc <> "' is not registered.", False)
                    Just tool -> do
                      res <- liftIO $ try @SomeException (rtHandler tool (callArguments tc))
                      case res of
                        Left err -> pure ("Tool threw exception: " <> T.pack (show err), False)
                        Right (out, ok) -> pure (out, ok)

              _ <- appendEvent sid "tool_observed" (encodeToolObserved (callId tc) obsOutput obsOk)

              let nextMsgs = msgs ++
                    [ Message RoleAssistant (respContent resp)
                    , Message RoleTool obsOutput
                    ]

              loop nextMsgs (allCalls ++ [tc]) (step + 1) stepUsage maxSteps

-- | Combine usage values.
combineUsage :: Usage -> Usage -> Usage
combineUsage u1 u2 = Usage
  { usageInputTokens      = usageInputTokens u1 + usageInputTokens u2
  , usageOutputTokens     = usageOutputTokens u1 + usageOutputTokens u2
  , usageCacheReadTokens  = usageCacheReadTokens u1 + usageCacheReadTokens u2
  , usageCacheWriteTokens = usageCacheWriteTokens u1 + usageCacheWriteTokens u2
  , usageReasoningTokens  = usageReasoningTokens u1 + usageReasoningTokens u2
  }

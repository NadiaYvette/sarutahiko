{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Hokora.Turn
-- Description : Autonomous single-turn ReAct program for the Skinny Spine protocol
--
-- Implements the single-turn ReAct execution loop per HOKORA_SPEC.md §6 and
-- PLAN.md §4 (Phase 1.5). Exercises ModelAPI, EventStore, and MCP tools over
-- capability typeclasses under the Façade Pattern.
module Hokora.Turn
  ( -- * ReAct Turn Program
    executeTurn
  , defaultHokoraTools
  , combineUsage

    -- * MCP Integration Helpers
  , mkStandardEchoServer
  , dispatchMcpServer
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Hokora.Types
  ( TurnResult (..)
  , encodeMessagePayload
  , encodeSessionClosed
  , encodeSessionOpened
  , encodeToolInvoked
  , encodeToolObserved
  )
import Sarutahiko.Effect.EventStore (SessionId)
import Sarutahiko.Effect.ModelAPI
  ( CompletionReq (..)
  , CompletionResp (..)
  , Message (..)
  , Role (..)
  , ToolCall (..)
  , ToolDefinition (..)
  , Usage (..)
  , defaultModelOptions
  )
import Sarutahiko.MCP
  ( CallToolResult (..)
  , Implementation (..)
  , McpServer
  , ToolContent (..)
  , ToolDef (..)
  , handleMcpPayload
  , newMcpServer
  , parseCallToolResponse
  , registerTool
  )
import Sarutahiko.Schema.Types (SchemaNode (..))
import Utai.Capability (MonadModelAPI (..))
import Yamaarashi.Flow.Capability (MonadEventStore (..))

-- | Autonomous single-turn ReAct execution loop per HOKORA_SPEC.md §6.
--
-- 1. Appends 'session_opened' event to 'EventStore'.
-- 2. Appends user 'message' event to 'EventStore'.
-- 3. Queries 'ModelAPI' with available tools.
-- 4. If a tool call is requested (at most one per Hokora spec):
--    a. Appends 'tool_invoked' event.
--    b. Executes tool through the provided runner.
--    c. Appends 'tool_observed' event.
--    d. Queries 'ModelAPI' with the observation.
-- 5. Appends assistant 'message' event.
-- 6. Appends 'session_closed' event.
-- 7. Returns 'TurnResult'.
executeTurn
  :: (MonadModelAPI m, MonadEventStore m)
  => SessionId
  -> Text                              -- ^ Model name
  -> FilePath                          -- ^ Cwd
  -> Text                              -- ^ User prompt
  -> (ToolCall -> m (Text, Bool))      -- ^ Tool runner (MCP dispatcher)
  -> m TurnResult
executeTurn sid model cwd prompt toolRunner = do
  -- 1. Open session
  _ <- appendEvent sid "session_opened" (encodeSessionOpened model cwd)

  -- 2. Log user message
  _ <- appendEvent sid "message" (encodeMessagePayload RoleUser prompt)

  -- 3. Initial model completion
  let req1 = CompletionReq
        { reqModel    = model
        , reqMessages = [Message RoleUser prompt]
        , reqTools    = defaultHokoraTools
        , reqOptions  = defaultModelOptions
        }
  resp1 <- complete req1

  -- 4. ReAct branch: at most one tool call per Hokora spec
  case respToolCalls resp1 of
    [] -> do
      -- No tool call requested; assistant completes directly
      let finalContent = respContent resp1
      _ <- appendEvent sid "message" (encodeMessagePayload RoleAssistant finalContent)
      _ <- appendEvent sid "session_closed" (encodeSessionClosed "completed")
      evs <- readEvents sid
      pure TurnResult
        { trSessionId   = sid
        , trFinalReply  = finalContent
        , trToolCalls   = []
        , trEventsCount = length evs
        , trUsage       = respUsage resp1
        }

    (tc:_) -> do
      -- Tool call requested: invoke tool and observe result
      _ <- appendEvent sid "tool_invoked" (encodeToolInvoked (callName tc) (callId tc) (callArguments tc))
      (obsOutput, obsOk) <- toolRunner tc
      _ <- appendEvent sid "tool_observed" (encodeToolObserved (callId tc) obsOutput obsOk)

      -- Query model with observation
      let msgs2 =
            [ Message RoleUser prompt
            , Message RoleAssistant (respContent resp1)
            , Message RoleTool obsOutput
            ]
          req2 = CompletionReq
            { reqModel    = model
            , reqMessages = msgs2
            , reqTools    = []
            , reqOptions  = defaultModelOptions
            }
      resp2 <- complete req2

      -- Log final assistant message and close session
      let finalContent = respContent resp2
      _ <- appendEvent sid "message" (encodeMessagePayload RoleAssistant finalContent)
      _ <- appendEvent sid "session_closed" (encodeSessionClosed "completed")
      evs <- readEvents sid
      pure TurnResult
        { trSessionId   = sid
        , trFinalReply  = finalContent
        , trToolCalls   = [tc]
        , trEventsCount = length evs
        , trUsage       = combineUsage (respUsage resp1) (respUsage resp2)
        }

-- | Default tool definitions advertised in Hokora turn executions.
defaultHokoraTools :: [ToolDefinition]
defaultHokoraTools =
  [ ToolDefinition "echo" "Echoes the provided input argument" "{\"type\":\"object\",\"properties\":{\"input\":{\"type\":\"string\"}},\"required\":[\"input\"]}"
  ]

-- | Combine token usage across multi-step completions.
combineUsage :: Usage -> Usage -> Usage
combineUsage u1 u2 = Usage
  { usageInputTokens      = usageInputTokens u1 + usageInputTokens u2
  , usageOutputTokens     = usageOutputTokens u1 + usageOutputTokens u2
  , usageCacheReadTokens  = usageCacheReadTokens u1 + usageCacheReadTokens u2
  , usageCacheWriteTokens = usageCacheWriteTokens u1 + usageCacheWriteTokens u2
  , usageReasoningTokens  = usageReasoningTokens u1 + usageReasoningTokens u2
  }

-- ----------------------------------------------------------------------------
-- MCP Server Dispatcher
-- ----------------------------------------------------------------------------

-- | Create a standard in-process MCP server with initialized handshake and echo tool.
mkStandardEchoServer :: IO McpServer
mkStandardEchoServer = do
  server <- newMcpServer (Implementation "hokora-mcp-echo" "0.1.0")
  registerTool server
    (ToolDef "echo" (Just "Echo input") (SchemaObject Map.empty []))
    (\mArgs -> do
       let out = case mArgs of
             Just bs -> "echo: " <> TE.decodeUtf8 bs
             Nothing -> "echo: (empty)"
       pure (CallToolResult [TextContent out] False))

  -- Run handshake to satisfy the StateGuard invariant
  _ <- handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"hokora-client\",\"version\":\"0.1.0\"}}}"
  _ <- handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"
  pure server

-- | Dispatch a tool call through an MCP server instance over JSON-RPC wire format.
dispatchMcpServer :: McpServer -> ToolCall -> IO (Text, Bool)
dispatchMcpServer server tc = do
  let reqPayload =
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\""
        <> TE.encodeUtf8 (callName tc) <> "\",\"arguments\":" <> callArguments tc <> "}}"
  mResp <- handleMcpPayload server reqPayload
  case mResp of
    Nothing -> pure ("No response from MCP server", False)
    Just bs -> case parseCallToolResponse bs of
      Left err -> pure ("MCP Error: " <> err, False)
      Right ctr ->
        let txts = [ t | TextContent t <- ctrContent ctr ]
        in pure (T.unlines txts, not (ctrIsError ctr))

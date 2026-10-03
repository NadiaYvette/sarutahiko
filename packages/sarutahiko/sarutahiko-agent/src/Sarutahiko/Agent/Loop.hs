{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Agent.Loop
-- Description : Multi-turn conversation agent session loop
--
-- Sequences multiple user prompts, preserves conversation history across turns,
-- and hydrates session context via SQLite event sourcing.
module Sarutahiko.Agent.Loop
  ( runAgentSession
  , runAgentSessionWithCarrier
  ) where

import Data.Text (Text)
import Effectful (Eff, IOE)

import Hashigakari.Sqlite (runEventStoreSqlite)
import Sarutahiko.Agent.Registry (ToolRegistry)
import Sarutahiko.Agent.Turn (AgentTurnResult (..), executeAgentTurn)
import Sarutahiko.Effect.EventStore (SessionId)
import Sarutahiko.Effect.ModelAPI (ModelAPI)
import Sarutahiko.Hooks.Allowlist (Allowlist)
import Sarutahiko.Session
  ( SessionContext (..)
  , SessionHandle (..)
  , readSessionContext
  , withSession
  )

-- | Run a sequence of turns in an agent session, persisting events to SQLite.
runAgentSession
  :: (forall a. Eff [ModelAPI, IOE] a -> IO a)
  -> FilePath           -- ^ SQLite database path
  -> SessionId          -- ^ Unique session ID
  -> Text               -- ^ Model
  -> FilePath           -- ^ Cwd
  -> ToolRegistry       -- ^ Tools
  -> Allowlist          -- ^ Consent allowlist
  -> [Text]             -- ^ Prompts to execute sequentially
  -> IO SessionContext
runAgentSession runModelCarrier dbPath sid model cwd registry allowlist prompts =
  withSession dbPath sid model cwd $ \handle -> do
    let runTurn prompt = do
          ctx <- readSessionContext handle
          _ <- runModelCarrier $ runEventStoreSqlite (shDatabase handle) $
            executeAgentTurn sid model cwd (scMessages ctx) prompt registry allowlist 5
          pure ()
    mapM_ runTurn prompts
    readSessionContext handle

-- | Convenience helper running under a pre-configured effect runner.
runAgentSessionWithCarrier
  :: (forall a. Eff [ModelAPI, IOE] a -> IO a)
  -> FilePath
  -> SessionId
  -> Text
  -> FilePath
  -> ToolRegistry
  -> Allowlist
  -> Text
  -> IO (AgentTurnResult, SessionContext)
runAgentSessionWithCarrier runModelCarrier dbPath sid model cwd registry allowlist prompt =
  withSession dbPath sid model cwd $ \handle -> do
    ctxPre <- readSessionContext handle
    turnRes <- runModelCarrier $ runEventStoreSqlite (shDatabase handle) $
      executeAgentTurn sid model cwd (scMessages ctxPre) prompt registry allowlist 5
    ctxPost <- readSessionContext handle
    pure (turnRes, ctxPost)

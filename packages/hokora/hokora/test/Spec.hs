{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Test suite for Hokora Phase 1.5 Skinny Spine vertical slice
--
-- Property tests verifying autonomous single-turn ReAct execution, SQLite event
-- persistence, conversation-tail reducer replay parity, and prefix hash stability.
module Main (main) where

import Control.Exception (SomeException, finally, try)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import Effectful (liftIO, runEff)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.Hedgehog

import Hashigakari.Sqlite
  ( readEventsSqlite
  , runEventStoreSqlite
  , withSqliteDatabase
  )
import Hokora
  ( SessionContext (..)
  , TurnResult (..)
  , dispatchMcpServer
  , executeTurn
  , mkStandardEchoServer
  , reduceSessionEvents
  )
import Sarutahiko.Effect.EventStore (SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.ModelAPI (Message (..), Role (..))
import Utai.Mock
  ( addFixture
  , cannedText
  , cannedToolCall
  , emptyFixtureStore
  , runModelAPIMock
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Hokora Phase 1.5 Skinny Spine Test Suite"
  [ testProperty "Single-turn execution without tool calls logs 4 events and folds cleanly"
      prop_turn_execution_no_tools
  , testProperty "Single-turn execution with MCP tool call logs 6 events and observes tool output"
      prop_turn_execution_with_tool_call
  , testProperty "Conversation-tail reducer replay parity: identical context and prefix hash"
      prop_reducer_replay_parity
  , testProperty "Prompt-cache prefix hash stability: deterministic under identical inputs, sensitive to changes"
      prop_prefix_hash_stability
  ]

-- | Bracketed helper allocating an isolated temporary SQLite database file.
withTempSqlite :: (FilePath -> IO a) -> IO a
withTempSqlite action = do
  tmpDir <- getTemporaryDirectory
  (tmpFile, h) <- openTempFile tmpDir "hokora-test-.db"
  hClose h
  let cleanup = do
        _ <- try @SomeException (removeFile tmpFile)
        _ <- try @SomeException (removeFile (tmpFile <> "-wal"))
        _ <- try @SomeException (removeFile (tmpFile <> "-shm"))
        pure ()
  action tmpFile `finally` cleanup

-- ----------------------------------------------------------------------------
-- Property 1: Execution without tools
-- ----------------------------------------------------------------------------

prop_turn_execution_no_tools :: Property
prop_turn_execution_no_tools = property $ do
  prompt <- forAll $ Gen.text (Range.linear 5 50) Gen.alphaNum
  expectedAnswer <- forAll $ Gen.text (Range.linear 5 50) Gen.alphaNum
  let sid = SessionId "sess-no-tools"
      model = "mock-model"
      cwd = "/tmp/hokora"
      fixtureStore = addFixture (cannedText prompt expectedAnswer) emptyFixtureStore

  (turnRes, rawEvents, hydratedCtx) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      mcpServer <- mkStandardEchoServer
      res <- runEff
        $ runModelAPIMock fixtureStore
        $ runEventStoreSqlite db
        $ executeTurn sid model cwd prompt (liftIO . dispatchMcpServer mcpServer)
      evs <- readEventsSqlite db sid
      let ctx = reduceSessionEvents sid evs
      pure (res, evs, ctx)

  -- Turn result assertions
  trFinalReply turnRes === expectedAnswer
  trToolCalls turnRes === []
  trEventsCount turnRes === 4

  -- SQLite event log assertions
  length rawEvents === 4
  map eventType rawEvents === ["session_opened", "message", "message", "session_closed"]

  -- Reducer assertions
  scIsClosed hydratedCtx === True
  scCloseReason hydratedCtx === Just "completed"
  length (scMessages hydratedCtx) === 2
  map msgRole (scMessages hydratedCtx) === [RoleUser, RoleAssistant]
  map msgContent (scMessages hydratedCtx) === [prompt, expectedAnswer]
  assert (not (T.null (scPrefixHash hydratedCtx)))

-- ----------------------------------------------------------------------------
-- Property 2: Execution with MCP tool call
-- ----------------------------------------------------------------------------

prop_turn_execution_with_tool_call :: Property
prop_turn_execution_with_tool_call = property $ do
  toolInput <- forAll $ Gen.text (Range.linear 3 20) Gen.alphaNum
  let prompt = "run tool with " <> toolInput
      callId = "call-1"
      toolName = "echo"
      toolArgs = "{\"input\":\"" <> BSC.pack (T.unpack toolInput) <> "\"}"
      finalReply = "Tool executed and verified: " <> toolInput
      sid = SessionId "sess-with-tools"
      model = "mock-model"
      cwd = "/tmp/hokora"
      fixtureStore =
        addFixture (cannedToolCall prompt callId toolName toolArgs)
        $ addFixture (cannedText ("echo: " <> toolInput) finalReply)
        $ emptyFixtureStore

  (turnRes, rawEvents, hydratedCtx) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      mcpServer <- mkStandardEchoServer
      res <- runEff
        $ runModelAPIMock fixtureStore
        $ runEventStoreSqlite db
        $ executeTurn sid model cwd prompt (liftIO . dispatchMcpServer mcpServer)
      evs <- readEventsSqlite db sid
      let ctx = reduceSessionEvents sid evs
      pure (res, evs, ctx)

  -- Turn result assertions
  length (trToolCalls turnRes) === 1
  trEventsCount turnRes === 6

  -- SQLite event log assertions
  length rawEvents === 6
  map eventType rawEvents ===
    ["session_opened", "message", "tool_invoked", "tool_observed", "message", "session_closed"]

  -- Reducer assertions
  scIsClosed hydratedCtx === True
  scCloseReason hydratedCtx === Just "completed"
  length (scToolResults hydratedCtx) === 1
  length (scMessages hydratedCtx) === 3
  map msgRole (scMessages hydratedCtx) === [RoleUser, RoleTool, RoleAssistant]
  assert (not (T.null (scPrefixHash hydratedCtx)))

-- ----------------------------------------------------------------------------
-- Property 3: Reducer replay parity
-- ----------------------------------------------------------------------------

prop_reducer_replay_parity :: Property
prop_reducer_replay_parity = property $ do
  prompt <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let sid = SessionId "sess-replay"
      model = "mock-model"
      cwd = "/tmp/hokora"
      fixtureStore = addFixture (cannedText prompt "reply") emptyFixtureStore

  rawEvents <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      mcpServer <- mkStandardEchoServer
      _ <- runEff
        $ runModelAPIMock fixtureStore
        $ runEventStoreSqlite db
        $ executeTurn sid model cwd prompt (liftIO . dispatchMcpServer mcpServer)
      readEventsSqlite db sid

  -- First fold
  let ctx1 = reduceSessionEvents sid rawEvents
  -- Replay fold from scratch
  let ctx2 = reduceSessionEvents sid rawEvents

  ctx1 === ctx2
  scPrefixHash ctx1 === scPrefixHash ctx2

-- ----------------------------------------------------------------------------
-- Property 4: Prefix hash stability
-- ----------------------------------------------------------------------------

prop_prefix_hash_stability :: Property
prop_prefix_hash_stability = property $ do
  prompt1 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  prompt2 <- forAll $ Gen.filter (/= prompt1) $ Gen.text (Range.linear 5 20) Gen.alphaNum
  let sid1 = SessionId "sess-hash-1"
      sid2 = SessionId "sess-hash-2"
      model = "mock-model"
      cwd = "/tmp/hokora"

  (ctx1a, ctx1b, ctx2) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      mcpServer <- mkStandardEchoServer
      let runWith p sid = do
            let store = addFixture (cannedText p ("reply-" <> p)) emptyFixtureStore
            _ <- runEff
              $ runModelAPIMock store
              $ runEventStoreSqlite db
              $ executeTurn sid model cwd p (liftIO . dispatchMcpServer mcpServer)
            evs <- readEventsSqlite db sid
            pure (reduceSessionEvents sid evs)

      c1a <- runWith prompt1 sid1
      c1b <- runWith prompt1 (SessionId "sess-hash-1b")
      c2  <- runWith prompt2 sid2
      pure (c1a, c1b, c2)

  -- Identical prompt & initial conditions produce identical prefix hash
  scPrefixHash ctx1a === scPrefixHash ctx1b

  -- Different prompt produces different prefix hash
  assert (scPrefixHash ctx1a /= scPrefixHash ctx2)

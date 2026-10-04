{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, finally, try)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Set as Set
import qualified Data.Text as T
import Effectful (liftIO, runEff)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.Hedgehog

import Hashigakari.Sqlite (readEventsSqlite, runEventStoreSqlite, withSqliteDatabase)
import Sarutahiko.Agent
  ( AgentTurnResult (..)
  , RegisteredTool (..)
  , codingAgentRegistry
  , defaultAgentRegistry
  , executeAgentTurn
  , lookupTool
  , parseFieldString
  , runAgentSessionWithCarrier
  )
import Sarutahiko.Effect.EventStore (SessionId (..))
import Sarutahiko.Hooks.Allowlist (Allowlist (..), defaultAllowlist, emptyAllowlist)
import Sarutahiko.Session (SessionContext (..))
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
tests = testGroup "Sarutahiko Agent Core Test Suite"
  [ testProperty "Agent turn single step: completes without tool calls" prop_agent_turn_single_step
  , testProperty "Agent turn with tool: dispatches tool and observes output" prop_agent_turn_with_tool
  , testProperty "Agent turn consent denial: blocks unauthorized tools under safe mode" prop_agent_turn_consent_denial
  , testProperty "Agent turn iteration ceiling: fail-closed termination on max iterations" prop_agent_turn_iteration_ceiling
  , testProperty "Multi-turn session persistence: maintains context and prefix stability" prop_agent_multi_turn_session
  , testProperty "Autonomous coding tools: file lifecycle write, read, replace" prop_coding_tools_file_lifecycle
  , testProperty "Zero-Aeson parameter parsing: extracts string field cleanly" prop_zero_aeson_parameter_parsing
  ]

withTempSqlite :: (FilePath -> IO a) -> IO a
withTempSqlite action = do
  tmpDir <- getTemporaryDirectory
  (tmpFile, h) <- openTempFile tmpDir "agent-test-.db"
  hClose h
  let cleanup = do
        _ <- try @SomeException (removeFile tmpFile)
        _ <- try @SomeException (removeFile (tmpFile <> "-wal"))
        _ <- try @SomeException (removeFile (tmpFile <> "-shm"))
        pure ()
  action tmpFile `finally` cleanup

prop_agent_turn_single_step :: Property
prop_agent_turn_single_step = property $ do
  prompt <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  reply  <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let sid = SessionId "sess-agent-1"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store = addFixture (cannedText prompt reply) emptyFixtureStore

  (res, evs) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 1
  atrFinalReply res === reply
  length evs === 2 -- user message + assistant message

prop_agent_turn_with_tool :: Property
prop_agent_turn_with_tool = property $ do
  input <- forAll $ Gen.text (Range.linear 3 20) Gen.alphaNum
  let prompt = "call echo with " <> input
      callId = "call-101"
      toolName = "echo"
      toolArgs = BSC.pack (T.unpack input)
      finalAnswer = "Successfully echoed: " <> input
      sid = SessionId "sess-agent-tool"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store =
        addFixture (cannedText (prompt <> "\n\necho: " <> input) finalAnswer)
        $ addFixture (cannedToolCall prompt callId toolName toolArgs)
        $ emptyFixtureStore

  (res, evs) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 2
  length (atrToolCalls res) === 1
  length evs === 4 -- message (user), tool_invoked, tool_observed, message (assistant)

prop_agent_turn_consent_denial :: Property
prop_agent_turn_consent_denial = property $ do
  let prompt = "run unauthorized tool"
      callId = "call-unauth"
      toolName = "rm_rf"
      toolArgs = "{}"
      sid = SessionId "sess-consent"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      strictAllowlist = emptyAllowlist { alApprovedTools = Set.empty, alSafeMode = True }
      store =
        addFixture (cannedText (prompt <> "\n\nExecution blocked") "Safe mode blocked the dangerous call.")
        $ addFixture (cannedToolCall prompt callId toolName toolArgs)
        $ emptyFixtureStore

  (res, _) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry strictAllowlist 5
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === True
  atrStepsTaken res === 2

prop_agent_turn_iteration_ceiling :: Property
prop_agent_turn_iteration_ceiling = property $ do
  -- Tool call that loops indefinitely: every response asks for another tool call
  let prompt = "loop forever"
      callId = "call-loop"
      toolName = "echo"
      toolArgs = "{\"input\":\"loop\"}"
      sid = SessionId "sess-loop"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store = addFixture (cannedToolCall prompt callId toolName toolArgs) emptyFixtureStore

  (res, _) <- liftIO $ withTempSqlite $ \dbPath ->
    withSqliteDatabase dbPath $ \db -> do
      r <- runEff
        $ runModelAPIMock store
        $ runEventStoreSqlite db
        $ executeAgentTurn sid model cwd [] prompt defaultAgentRegistry defaultAllowlist 3
      raw <- readEventsSqlite db sid
      pure (r, raw)

  atrCompleted res === False
  atrStepsTaken res === 3
  assert ("Iteration ceiling reached" `T.isInfixOf` atrFinalReply res)

prop_agent_multi_turn_session :: Property
prop_agent_multi_turn_session = property $ do
  p1 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  p2 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  let sid = SessionId "sess-multi"
      model = "mock-model"
      cwd = "/tmp/sarutahiko"
      store =
        addFixture (cannedText p1 "Reply 1")
        $ addFixture (cannedText p2 "Reply 2")
        $ emptyFixtureStore

  ctx <- liftIO $ withTempSqlite $ \dbPath -> do
    _ <- runAgentSessionWithCarrier
      (runEff . runModelAPIMock store)
      dbPath
      sid
      model
      cwd
      defaultAgentRegistry
      defaultAllowlist
      p1
    (_, c2) <- runAgentSessionWithCarrier
      (runEff . runModelAPIMock store)
      dbPath
      sid
      model
      cwd
      defaultAgentRegistry
      defaultAllowlist
      p2
    pure c2

  length (scMessages ctx) === 4 -- [user1, assistant1, user2, assistant2]
  assert (not (T.null (scPrefixHash ctx)))

prop_coding_tools_file_lifecycle :: Property
prop_coding_tools_file_lifecycle = property $ do
  origText <- forAll $ Gen.text (Range.linear 10 50) Gen.alphaNum
  replText <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum

  let writeTool = lookupTool "write_file" codingAgentRegistry
      readTool  = lookupTool "read_file" codingAgentRegistry
      replTool  = lookupTool "replace_file_content" codingAgentRegistry

  case (writeTool, readTool, replTool) of
    (Just wt, Just rt, Just rpt) -> do
      (readRes1, readRes2, ok1, ok2, ok3) <- evalIO $ do
        tmpDir <- getTemporaryDirectory
        (tmpFile, h) <- openTempFile tmpDir "tool-test-.txt"
        hClose h

        -- 1. Write file
        let writePayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\",\"content\":\"" <> BSC.pack (T.unpack origText) <> "\"}"
        (_, wOk) <- rtHandler wt writePayload

        -- 2. Read file
        let readPayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\"}"
        (r1, rOk) <- rtHandler rt readPayload

        -- 3. Replace substring
        let replPayload = "{\"path\":\"" <> BSC.pack tmpFile <> "\",\"target\":\"" <> BSC.pack (T.unpack origText) <> "\",\"replacement\":\"" <> BSC.pack (T.unpack replText) <> "\"}"
        (_, rpOk) <- rtHandler rpt replPayload

        -- 4. Read back replaced file
        (r2, _) <- rtHandler rt readPayload
        _ <- try @SomeException (removeFile tmpFile)
        pure (r1, r2, wOk, rOk, rpOk)

      ok1 === True
      ok2 === True
      ok3 === True
      readRes1 === origText
      readRes2 === replText
    _ -> failure

prop_zero_aeson_parameter_parsing :: Property
prop_zero_aeson_parameter_parsing = property $ do
  val <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let json = "{\"command\":\"" <> BSC.pack (T.unpack val) <> "\",\"other\":42}"
      extracted = parseFieldString "command" json
  extracted === Just val


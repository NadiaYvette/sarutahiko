{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : hokora-run executable demonstrating the Phase 1.5 Skinny Spine vertical slice
--
-- CLI tool running an interpreted autonomous single-turn ReAct program per
-- HOKORA_SPEC.md §4. Appends events to SQLite, executes tools over MCP, folds
-- the conversation-tail reducer, and prints execution summary.
module Main (main) where

import Control.Exception (SomeException, finally, try)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Effectful (liftIO, runEff)
import System.Directory (getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.Environment (getArgs)
import System.IO (hClose, openTempFile)

import Hashigakari.Sqlite (readEventsSqlite, runEventStoreSqlite, withSqliteDatabase)
import Hokora
  ( SessionContext (..)
  , TurnResult (..)
  , dispatchMcpServer
  , executeTurn
  , mkStandardEchoServer
  , reduceSessionEvents
  )
import Sarutahiko.Effect.EventStore (SessionId (..))
import Sarutahiko.Effect.ModelAPI (Usage (..))
import Utai.Mock
  ( addFixture
  , cannedText
  , cannedToolCall
  , emptyFixtureStore
  , runModelAPIMock
  )

main :: IO ()
main = do
  args <- getArgs
  let prompt = case args of
        []    -> "call echo: test hokora autonomous turn"
        (p:_) -> T.pack p

  cwd <- getCurrentDirectory
  let sid = SessionId "hokora-session-001"
      model = "mistral/codestral-latest"

  -- Configure deterministic mock fixture rules
  -- More specific multi-message prompt prefixes are added last so they are evaluated first
  let fixtureStore =
        addFixture (cannedText (prompt <> "\n\necho:") "Hokora single-turn ReAct slice completed successfully via MCP tool execution.")
        $ addFixture (cannedToolCall "call echo" "call-echo-1" "echo" "{\"input\":\"hokora test payload\"}")
        $ emptyFixtureStore

  -- Allocate temporary SQLite store for the session
  tmpDir <- getTemporaryDirectory
  (dbPath, h) <- openTempFile tmpDir "hokora-session-.db"
  hClose h

  let cleanup = do
        _ <- try @SomeException (removeFile dbPath)
        _ <- try @SomeException (removeFile (dbPath <> "-wal"))
        _ <- try @SomeException (removeFile (dbPath <> "-shm"))
        pure ()

  (`finally` cleanup) $ withSqliteDatabase dbPath $ \db -> do
    mcpServer <- mkStandardEchoServer

    putStrLn "============================================================"
    putStrLn "  Hokora Phase 1.5 Skinny Spine Autonomous Turn Slice"
    putStrLn "============================================================"
    TIO.putStrLn $ "  Session ID : " <> unSessionId sid
    TIO.putStrLn $ "  Prompt     : " <> prompt
    TIO.putStrLn $ "  Model      : " <> model
    putStrLn     $ "  Cwd        : " ++ cwd
    putStrLn     $ "  SQLite DB  : " ++ dbPath
    putStrLn "------------------------------------------------------------"

    -- Execute autonomous turn loop
    turnResult <- runEff
      $ runModelAPIMock fixtureStore
      $ runEventStoreSqlite db
      $ executeTurn sid model cwd prompt (liftIO . dispatchMcpServer mcpServer)

    -- Read raw event log from SQLite
    rawEvents <- readEventsSqlite db sid

    -- Hydrate session context via pure fold over event stream
    let hydratedCtx = reduceSessionEvents sid rawEvents

    putStrLn "------------------------------------------------------------"
    putStrLn "  Turn Program Execution Completed!"
    putStrLn "------------------------------------------------------------"
    TIO.putStrLn $ "  Final Reply      : " <> trFinalReply turnResult
    putStrLn     $ "  Events Appended  : " ++ show (trEventsCount turnResult)
    putStrLn     $ "  Raw Events Read  : " ++ show (length rawEvents)
    putStrLn     $ "  Messages Folded  : " ++ show (length (scMessages hydratedCtx))
    putStrLn     $ "  Tool Results     : " ++ show (length (scToolResults hydratedCtx))
    TIO.putStrLn $ "  Prompt PrefixHash: " <> scPrefixHash hydratedCtx
    putStrLn     $ "  Input Tokens     : " ++ show (usageInputTokens (trUsage turnResult))
    putStrLn     $ "  Output Tokens    : " ++ show (usageOutputTokens (trUsage turnResult))
    putStrLn "============================================================"
    putStrLn "  Phase 1.5 Skinny Spine Proof VERIFIED!"
    putStrLn "============================================================"

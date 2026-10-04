{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (SomeException, finally, try)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Effectful (runEff)
import System.Directory (getCurrentDirectory, getTemporaryDirectory, removeFile)
import System.Environment (getArgs)
import System.IO (hClose, openTempFile)

import Sarutahiko.Agent
  ( AgentTurnResult (..)
  , codingAgentRegistry
  , runAgentSessionWithCarrier
  , runModelAPILive
  )
import Sarutahiko.Effect.EventStore (SessionId (..))
import Sarutahiko.Effect.ModelAPI (Usage (..))
import Sarutahiko.Hooks.Allowlist (defaultAllowlist)
import Sarutahiko.Session (SessionContext (..))
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
  let (isLive, remainingArgs) = parseLiveFlag args
  case remainingArgs of
    ("chat" : promptStrs) -> runAgentMode isLive (if null promptStrs then ["Hello, Sarutahiko agent!"] else map T.pack promptStrs)
    ("run" : promptStrs)  -> runAgentMode isLive (if null promptStrs then ["call echo: autonomous test"] else [T.unwords (map T.pack promptStrs)])
    (p:ps)                -> runAgentMode isLive [T.unwords (map T.pack (p:ps))]
    []                    -> runAgentMode isLive ["call echo: default agent run"]

parseLiveFlag :: [String] -> (Bool, [String])
parseLiveFlag [] = (False, [])
parseLiveFlag ("--live" : rest) = (True, snd (parseLiveFlag rest))
parseLiveFlag ("--mock" : rest) = (False, snd (parseLiveFlag rest))
parseLiveFlag (x : rest)        = let (live, rest') = parseLiveFlag rest in (live, x : rest')

runAgentMode :: Bool -> [T.Text] -> IO ()
runAgentMode isLive prompts = do
  cwd <- getCurrentDirectory
  let sid = SessionId "sarutahiko-session-001"
      model = "mistral/codestral-latest"

  -- Allocate temporary SQLite database
  tmpDir <- getTemporaryDirectory
  (dbPath, h) <- openTempFile tmpDir "sarutahiko-agent-.db"
  hClose h

  let cleanup = do
        _ <- try @SomeException (removeFile dbPath)
        _ <- try @SomeException (removeFile (dbPath <> "-wal"))
        _ <- try @SomeException (removeFile (dbPath <> "-shm"))
        pure ()

  let p1 = case prompts of
        (p:_) -> p
        []    -> "call echo: default agent run"
      store =
        addFixture (cannedText (p1 <> "\n\necho:") "Sarutahiko agent successfully processed your request via tool execution.")
        $ addFixture (cannedToolCall "call echo" "call-echo-1" "echo" "{\"input\":\"agent payload\"}")
        $ addFixture (cannedText p1 "Hello! I am Sarutahiko, the guiding agent. How can I assist you?")
        $ emptyFixtureStore

  (`finally` cleanup) $ do
    putStrLn "============================================================"
    putStrLn "  Sarutahiko Autonomous Agent Core (Phase 5)"
    putStrLn "============================================================"
    TIO.putStrLn $ "  Session ID : " <> unSessionId sid
    TIO.putStrLn $ "  Prompt     : " <> p1
    TIO.putStrLn $ "  Model      : " <> model
    putStrLn     $ "  Execution  : " ++ (if isLive then "Live Utai (OmniRoute/OpenCode)" else "Mock (In-Memory)")
    putStrLn     $ "  Cwd        : " ++ cwd
    putStrLn     $ "  Database   : " ++ dbPath
    putStrLn "------------------------------------------------------------"

    (res, ctx) <-
      if isLive
        then runAgentSessionWithCarrier
               (runEff . runModelAPILive model)
               dbPath
               sid
               model
               cwd
               codingAgentRegistry
               defaultAllowlist
               p1
        else runAgentSessionWithCarrier
               (runEff . runModelAPIMock store)
               dbPath
               sid
               model
               cwd
               codingAgentRegistry
               defaultAllowlist
               p1

    putStrLn "------------------------------------------------------------"
    putStrLn "  Agent Execution Complete"
    putStrLn "------------------------------------------------------------"
    TIO.putStrLn $ "  Final Response   : " <> atrFinalReply res
    putStrLn     $ "  Steps Taken      : " ++ show (atrStepsTaken res)
    putStrLn     $ "  Tool Calls       : " ++ show (length (atrToolCalls res))
    putStrLn     $ "  Context Messages : " ++ show (length (scMessages ctx))
    TIO.putStrLn $ "  Prefix Hash      : " <> scPrefixHash ctx
    putStrLn     $ "  Total Tokens     : " ++ show (usageInputTokens (atrUsage res) + usageOutputTokens (atrUsage res))
    putStrLn "============================================================"

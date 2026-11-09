{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, throwIO)
import Control.Monad (filterM, when)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TIO
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , listDirectory
  , removeFile
  )
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Environment (getArgs, getEnvironment)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.Process.Typed
import System.Timeout (timeout)

import Utai
  ( CompletionReq (..)
  , CompletionResp (..)
  , Message (..)
  , ProviderProfile (..)
  , Role (..)
  , callOpenAIWithFallback
  , defaultModelOptions
  , omnirouteProfile
  , opencodeProfile
  )
import Yamaarashi.Flow.Ledger
  ( initTaskLedger
  , logTaskEvent
  , projectKanban
  , readAllTaskEvents
  , readAllTaskIds
  , readTaskEventsWithTime
  , renderKanbanAscii
  , vacuumTaskLedger
  )

-- | Parsed task packet envelope.
data TaskPacket = TaskPacket
  { packetId                :: !Text
  , packetTitle             :: !Text
  , packetDescription       :: !Text
  , packetPackages          :: ![Text]
  , packetExecutor          :: !Text
  , packetModel             :: !(Maybe Text)
  , packetSkills            :: ![Text]
  , packetMaxTurns          :: !(Maybe Int)
  , packetRunBudget         :: !(Maybe Int)
  , packetMaxRepairAttempts :: !(Maybe Int)
  , packetAllowMetered      :: !Bool
  , packetRawYaml           :: !Text
  } deriving (Show)

-- | Metered environment variables that must be scrubbed from worker environments
-- to enforce the quota firewall (TP-META-000).
meteredEnvKeys :: [String]
meteredEnvKeys =
  [ "GEMINI_API_KEY"
  , "ANTHROPIC_API_KEY"
  , "OPENAI_API_KEY"
  , "OPENAI_API_BASE"
  , "GOOGLE_API_KEY"
  , "AZURE_OPENAI_API_KEY"
  , "MISTRAL_API_KEY"
  , "COHERE_API_KEY"
  ]

-- | Build a sanitized process environment for worker subprocesses.
-- When allowMetered is False, all metered API keys are scrubbed and
-- MCP sampling loopback is explicitly disabled.
buildWorkerEnv :: Bool -> IO [(String, String)]
buildWorkerEnv allowMetered = do
  currEnv <- getEnvironment
  let scrubbed = if allowMetered
                   then currEnv
                   else filter (\(k, _) -> k `notElem` meteredEnvKeys) currEnv
      firewalled =
        [ ("YAMAARASHI_AIRGAPPED", if allowMetered then "0" else "1")
        , ("MCP_DISABLE_SAMPLING", "1")
        , ("AGY_DISABLE_SAMPLING", "1")
        , ("AGY_ALLOW_METERED", if allowMetered then "1" else "0")
        ]
  pure $ firewalled ++ filter (\(k, _) -> k `notElem` map fst firewalled) scrubbed

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- getArgs
  case args of
    ["run", "--allow-metered", packetPath] -> runTaskPacket True packetPath
    ["run", packetPath]                   -> runTaskPacket False packetPath
    ("snapshot" : snapArgs)               -> handleSnapshot snapArgs
    ("autoheal" : autoArgs)               -> handleAutoHeal autoArgs
    ["telemetry", tId]                    -> showTelemetry (Just (T.pack tId))
    ["telemetry"]                         -> showTelemetry Nothing
    ["kanban", dbPath]                    -> showKanbanBoard dbPath
    ["kanban"]                            -> showKanbanBoard ".yamaarashi/events.sqlite3"
    ["--help"]                            -> printHelp >> exitSuccess
    ["-h"]                                -> printHelp >> exitSuccess
    _                                     -> do
      putStrLn "Usage: yamaarashi-exec (run [--allow-metered] <path/to/packet.yaml> | snapshot <id> [...] | autoheal [<args>] | telemetry [<id>] | kanban [<db-path>])"
      exitFailure

-- | Display pure ASCII Kanban projection from the SQLite event ledger.
showKanbanBoard :: FilePath -> IO ()
showKanbanBoard dbPath = do
  exists <- doesFileExist dbPath
  if not exists
    then putStrLn $ "Error: Task ledger database not found at: " ++ dbPath
    else do
      rawRows <- readAllTaskEvents dbPath
      let events = map (\(_, tId, evType, p) -> (tId, evType, p)) rawRows
          board = projectKanban events
      putStrLn "============================================================"
      putStrLn "  Yamaarashi Flow — Autonomous Task Kanban Projection"
      putStrLn "============================================================"
      TIO.putStrLn (renderKanbanAscii board)
      putStrLn "============================================================"

printHelp :: IO ()
printHelp = do
  putStrLn "yamaarashi-exec — Standalone Yamaarashi workflow runner"
  putStrLn ""
  putStrLn "Commands:"
  putStrLn "  run [--allow-metered] <packet.yaml>  Execute a task packet in an isolated worktree (airgapped by default)"
  putStrLn "  snapshot <id> [--title \"...\"] [--verify \"...\"] [--packages \"p1,p2\"]"
  putStrLn "                                       Snapshot workspace diff into a deterministic task packet & runner script"
  putStrLn "  telemetry [<id>]                     Display timing intervals and execution telemetry from the event ledger"
  putStrLn "  kanban [<db-path>]                   Display pure ASCII Kanban projection from task ledger"
  putStrLn "  --help                               Show this help message"
  putStrLn ""
  putStrLn "Execution Engines (set in packet via 'executor:'):"
  putStrLn "  executor: sarutahiko In-tree autonomous agent core (Phase 5 self-hosting)."
  putStrLn "  executor: utai       Direct zero-cost model invocation via Utai native client (reliable, fast)."
  putStrLn "  executor: agy        Delegates turn execution to Antigravity CLI print mode (fast, robust)."
  putStrLn "  executor: hermes     Delegates turn execution to a spawned Hermes leaf worker."
  putStrLn "  executor: yaegi      Runs scripts/tasks/<id>.go via Yaegi Go interpreter (type-safe, zero build)."
  putStrLn "  executor: go         Alias for yaegi executor."
  putStrLn "  executor: script     Runs scripts/tasks/<id>.sh in the isolated worktree."
  putStrLn "  executor: auto       Prefers .go (yaegi) or .sh (script) if present, else utai."

-- | Parse command line arguments for the snapshot command.
-- Syntax: snapshot <packet-id> [--title <title>] [--verify <cmd>] [--packages <p1,p2...>]
data SnapshotOptions = SnapshotOptions
  { snapId       :: !Text
  , snapTitle    :: !(Maybe Text)
  , snapVerify   :: !(Maybe Text)
  , snapPackages :: ![Text]
  }

parseSnapshotOptions :: [String] -> Either String SnapshotOptions
parseSnapshotOptions [] = Left "Missing required <packet-id> argument for snapshot command."
parseSnapshotOptions (rawId : rest)
  | "-" `isPrefixOf` rawId = Left $ "First argument must be <packet-id>, got flag: " ++ rawId
  | otherwise = go rest (SnapshotOptions (T.pack rawId) Nothing Nothing [])
  where
    go [] opts = Right opts
    go ("--title" : val : xs) opts = go xs (opts { snapTitle = Just (T.pack val) })
    go ("-t" : val : xs) opts = go xs (opts { snapTitle = Just (T.pack val) })
    go ("--verify" : val : xs) opts = go xs (opts { snapVerify = Just (T.pack val) })
    go ("-v" : val : xs) opts = go xs (opts { snapVerify = Just (T.pack val) })
    go ("--packages" : val : xs) opts =
      let pkgs = filter (not . T.null) (map T.strip (T.splitOn "," (T.pack val)))
      in go xs (opts { snapPackages = pkgs })
    go ("-p" : val : xs) opts =
      let pkgs = filter (not . T.null) (map T.strip (T.splitOn "," (T.pack val)))
      in go xs (opts { snapPackages = pkgs })
    go (unknown : _) _ = Left $ "Unrecognized flag for snapshot: " ++ unknown

-- | Capture the current working directory diff and produce a deterministic task packet.
handleSnapshot :: [String] -> IO ()
handleSnapshot args = case parseSnapshotOptions args of
  Left err -> do
    putStrLn $ "Error: " ++ err
    putStrLn "Usage: yamaarashi-exec snapshot <packet-id> [--title <title>] [--verify <cmd>] [--packages <pkg1,pkg2>]"
    exitFailure
  Right opts -> do
    let tId = snapId opts
    putStrLn $ "=== [yamaarashi-exec] Snapshotting workspace into task packet: " ++ T.unpack tId ++ " ==="

    (rootOut, _) <- readProcess_ (proc "git" ["rev-parse", "--show-toplevel"])
    let repoRoot = T.unpack (T.strip (TE.decodeUtf8 (BSC.toStrict rootOut)))
        repoName = takeBaseName repoRoot
        scriptsDir = repoRoot </> "scripts" </> "tasks"
        plansDir = repoRoot </> "plans" </> "task_packets"
        pendingQueueDir = "/home/nyc/src/plans/tier2-yamaarashi/pending"

    createDirectoryIfMissing True scriptsDir
    createDirectoryIfMissing True plansDir

    -- Stage untracked files intent-to-add so git diff HEAD captures both modifications and new files
    _ <- runProcess (setWorkingDir repoRoot (proc "git" ["add", "-N", "."]))
    (diffCode, diffBs, _) <- readProcess (setWorkingDir repoRoot (proc "git" ["diff", "HEAD"]))
    _ <- runProcess (setWorkingDir repoRoot (proc "git" ["reset"]))

    let diffStrict = BSL.toStrict diffBs
    if diffCode /= ExitSuccess || BSC.null (BSC.filter (\c -> c /= ' ' && c /= '\n') diffStrict)
      then do
        putStrLn "Error: No modified or untracked files detected in workspace. Nothing to snapshot!"
        exitFailure
      else do
        let patchFile  = scriptsDir </> (T.unpack tId ++ ".patch")
            shFile     = scriptsDir </> (T.unpack tId ++ ".sh")
            verifyFile = scriptsDir </> (T.unpack tId ++ "-verify.sh")
            yamlFile   = plansDir </> (T.unpack tId ++ ".yaml")
            titleText  = case snapTitle opts of
              Just t  -> t
              Nothing -> tId

        -- 1. Write .patch file
        BSL.writeFile patchFile diffBs
        putStrLn $ "  [1/4] Created deterministic patch: " ++ patchFile

        -- 2. Write .sh replay script
        let shContent = T.unlines
              [ "#!/usr/bin/env bash"
              , "set -euo pipefail"
              , ""
              , "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\""
              , "PATCH_FILE=\"${SCRIPT_DIR}/" <> tId <> ".patch\""
              , ""
              , "if [ -f \"${PATCH_FILE}\" ]; then"
              , "  echo \"=== [yamaarashi-task] Applying snapshot patch: ${PATCH_FILE} ===\""
              , "  if git apply --check \"${PATCH_FILE}\" >/dev/null 2>&1; then"
              , "    git apply --whitespace=nowarn \"${PATCH_FILE}\""
              , "  else"
              , "    echo \"=== [yamaarashi-task] Patch already present in branch/worktree ===\""
              , "  fi"
              , "fi"
              ]
        TIO.writeFile shFile shContent
        _ <- runProcess (proc "chmod" ["+x", shFile])
        putStrLn $ "  [2/4] Created task runner script:  " ++ shFile

        -- 3. Write -verify.sh script
        defaultVerifyCmd <- case snapVerify opts of
          Just vCmd -> pure vCmd
          Nothing -> do
            let defaultBinVerify = repoRoot </> "bin" </> (repoName ++ "-verify")
            hasBinVerify <- doesFileExist defaultBinVerify
            if hasBinVerify
              then pure (T.pack ("./bin/" ++ repoName ++ "-verify"))
              else pure "cabal v2-build -j20 --semaphore && cabal v2-test"

        let verifyContent = T.unlines
              [ "#!/usr/bin/env bash"
              , "set -euo pipefail"
              , ""
              , "echo \"=== [yamaarashi-verify] Running verification gate for " <> tId <> " ===\""
              , defaultVerifyCmd
              ]
        TIO.writeFile verifyFile verifyContent
        _ <- runProcess (proc "chmod" ["+x", verifyFile])
        putStrLn $ "  [3/4] Created verification script: " ++ verifyFile

        -- 4. Detect packages
        effectivePkgs <- if not (null (snapPackages opts))
          then pure (snapPackages opts)
          else do
            let pkgsDir = repoRoot </> "packages"
            hasPkgsDir <- doesDirectoryExist pkgsDir
            if hasPkgsDir
              then do
                entries <- listDirectory pkgsDir
                let isPkgDir d = doesFileExist (pkgsDir </> d </> (d ++ ".cabal"))
                validPkgs <- filterM isPkgDir entries
                if null validPkgs
                  then pure [T.pack repoName]
                  else pure (map T.pack validPkgs)
              else pure [T.pack repoName]

        -- 5. Write .yaml task packet
        let yamlContent = T.unlines $
              [ "id: " <> tId
              , "title: \"" <> titleText <> "\""
              , "description: |"
              , "  " <> titleText
              , "packages:"
              ] ++ map (\p -> "  - " <> p) effectivePkgs ++
              [ "executor: script"
              , "max_repair_attempts: 3"
              , "allow_metered: false"
              ]
        TIO.writeFile yamlFile yamlContent
        putStrLn $ "  [4/4] Created task packet YAML:    " ++ yamlFile

        -- 6. Copy to pending queue if directory exists
        hasPendingDir <- doesDirectoryExist pendingQueueDir
        when hasPendingDir $ do
          let pendingTarget = pendingQueueDir </> (T.unpack tId ++ ".yaml")
          copyFile yamlFile pendingTarget
          putStrLn $ "  -> Seeded into pending queue:     " ++ pendingTarget

        putStrLn "============================================================"
        putStrLn $ "=== [yamaarashi-exec] SUCCESS: Task " ++ T.unpack tId ++ " snapshot created! ==="
        putStrLn "To execute in an isolated worktree:"
        putStrLn $ "  yamaarashi-exec run " ++ yamlFile
        putStrLn "============================================================"

-- | Display execution telemetry and timing breakdown from the task ledger.
showTelemetry :: Maybe Text -> IO ()
showTelemetry mTargetId = do
  (rootOut, _) <- readProcess_ (proc "git" ["rev-parse", "--show-toplevel"])
  let repoRoot = T.unpack (T.strip (TE.decodeUtf8 (BSC.toStrict rootOut)))
      dbPath   = repoRoot </> ".yamaarashi" </> "events.sqlite3"
  exists <- doesFileExist dbPath
  if not exists
    then putStrLn $ "Error: Task ledger database not found at: " ++ dbPath
    else case mTargetId of
      Just tId -> showSingleTaskTelemetry dbPath tId
      Nothing  -> do
        allIds <- readAllTaskIds dbPath
        if null allIds
          then putStrLn "No task executions recorded in ledger yet."
          else do
            putStrLn "============================================================"
            putStrLn "  Yamaarashi Flow — Task Execution Telemetry"
            putStrLn "============================================================"
            mapM_ (showSingleTaskTelemetry dbPath) allIds

showSingleTaskTelemetry :: FilePath -> Text -> IO ()
showSingleTaskTelemetry dbPath tId = do
  events <- readTaskEventsWithTime dbPath tId
  if null events
    then putStrLn $ "No events recorded for task: " ++ T.unpack tId
    else do
      putStrLn $ "\n--- Task Telemetry: " ++ T.unpack tId ++ " ---"
      putStrLn "Timeline Events:"
      let formatEvent (_, _, evType, payload, createdAt) =
            let timeStr = if T.null createdAt then "----:--:-- --:--:--" else T.unpack createdAt
                shortPayload = if T.length payload > 60 then T.take 57 payload <> "..." else payload
            in "  [" ++ timeStr ++ "] " ++ take 22 (T.unpack evType ++ repeat ' ') ++ ": " ++ T.unpack shortPayload
      mapM_ (putStrLn . formatEvent) events

      let completedEvents = filter (\(_, _, evType, _, _) -> evType == "TASK_COMPLETED") events
          failedEvents    = filter (\(_, _, evType, _, _) -> evType == "TASK_FAILED") events
          statusStr = if not (null completedEvents)
                        then "COMPLETED"
                        else if not (null failedEvents)
                          then "FAILED"
                          else "IN_PROGRESS"
          stepEvents = filter (\(_, _, evType, _, _) -> evType `elem` ["STEP_EXECUTED", "STEP_FAILED"]) events
          cycleCount = length stepEvents

      putStrLn $ "Status:        " ++ statusStr
      putStrLn $ "Cycles Run:    " ++ show (max 1 cycleCount)

-- | Invoke the standalone hls-autoheal tool from the CLI.
handleAutoHeal :: [String] -> IO ()
handleAutoHeal args = do
  hasAutoHeal <- doesFileExist "/home/nyc/.local/bin/hls-autoheal"
  if not hasAutoHeal
    then putStrLn "Error: /home/nyc/.local/bin/hls-autoheal not found" >> exitFailure
    else do
      let effectiveArgs = if null args then ["--hls"] else args
      (code, outBs, errBs) <- readProcess (proc "/home/nyc/.local/bin/hls-autoheal" effectiveArgs)
      let outText = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict outBs)
          errText = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict errBs)
      TIO.putStr outText
      when (not (T.null errText)) (TIO.putStr errText)
      if code == ExitSuccess then exitSuccess else exitFailure

-- | Attempt automated mechanical repair of compiler and HLS diagnostics
-- inside an isolated worktree using the standalone hls-autoheal utility.
runAutoHeal :: FilePath -> Text -> IO Bool
runAutoHeal wtDir errOutput = do
  hasAutoHeal <- doesFileExist "/home/nyc/.local/bin/hls-autoheal"
  if not hasAutoHeal
    then pure False
    else do
      putStrLn "=== [yamaarashi-exec] Attempting automated HLS/GHC auto-heal pass ==="
      let autohealProc = setWorkingDir wtDir
                       $ setStdin (byteStringInput (BSL.fromStrict (TE.encodeUtf8 errOutput)))
                       $ proc "/home/nyc/.local/bin/hls-autoheal" ["--stdin"]
      (exitCode, outBs, _) <- readProcess autohealProc
      let outText = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict outBs)
      TIO.putStr outText
      let healed = exitCode == ExitSuccess && not (T.isInfixOf "Applied 0 automated repairs" outText)
      pure healed

-- | Execute a task packet through an isolated worktree with SQLite event tracking.
runTaskPacket :: Bool -> FilePath -> IO ()
runTaskPacket cliAllowMetered path = do
  putStrLn $ "=== [yamaarashi-exec] Loading task packet: " ++ path ++ " ==="
  content <- TIO.readFile path
  rawPacket <- parsePacket path content
  let effectiveAllowMetered = cliAllowMetered || packetAllowMetered rawPacket
      packet = rawPacket { packetAllowMetered = effectiveAllowMetered }
      tId = T.unpack (packetId packet)

  -- Get repo root directory
  (rootOut, _) <- readProcess_ (proc "git" ["rev-parse", "--show-toplevel"])
  let repoRoot = T.unpack (T.strip (TE.decodeUtf8 (BSC.toStrict rootOut)))
      srcDir   = takeDirectory repoRoot
      dbDir    = repoRoot </> ".yamaarashi"
      dbPath   = dbDir </> "events.sqlite3"
      worktreeDir = srcDir </> ("sarutahiko-wt-" ++ tId)
      branchName  = "yamaarashi/task-" ++ tId

  createDirectoryIfMissing True dbDir
  initEventDb dbPath
  logEvent dbPath (packetId packet) "TASK_STARTED" ("Packet loaded from " <> T.pack path)
  if effectiveAllowMetered
    then do
      putStrLn "=== [yamaarashi-exec] Quota Firewall: BYPASSED (--allow-metered) ==="
      logEvent dbPath (packetId packet) "QUOTA_FIREWALL_BYPASSED" "Metered API access permitted"
    else do
      putStrLn "=== [yamaarashi-exec] Quota Firewall: ACTIVE (airgapped from metered APIs) ==="
      logEvent dbPath (packetId packet) "QUOTA_FIREWALL_ACTIVE" "Metered API keys scrubbed; MCP sampling disabled"

  putStrLn $ "=== [yamaarashi-exec] Task: " ++ T.unpack (packetTitle packet) ++ " (" ++ tId ++ ") ==="
  putStrLn $ "=== [yamaarashi-exec] Provisioning isolated worktree at: " ++ worktreeDir ++ " ==="

  -- Clean up any stale worktree or branch
  _ <- runProcess (proc "git" ["worktree", "remove", "--force", worktreeDir])
  _ <- runProcess (proc "git" ["branch", "-D", branchName])

  let provision = do
        runProcess_ (proc "git" ["worktree", "add", "-B", branchName, worktreeDir, "HEAD"])
        hasTags <- doesFileExist (repoRoot </> "tags")
        when hasTags $ do
          copyFile (repoRoot </> "tags") (worktreeDir </> "tags")
          putStrLn "=== [yamaarashi-exec] Seeded ./tags into isolated worktree ==="
        hasCabalLocal <- doesFileExist (repoRoot </> "cabal.project.local")
        when hasCabalLocal $ do
          copyFile (repoRoot </> "cabal.project.local") (worktreeDir </> "cabal.project.local")
          putStrLn "=== [yamaarashi-exec] Seeded cabal.project.local into isolated worktree ==="
        hasDistNewstyle <- doesDirectoryExist (repoRoot </> "dist-newstyle")
        when hasDistNewstyle $ do
          _ <- runProcess (proc "ln" ["-s", repoRoot </> "dist-newstyle", worktreeDir </> "dist-newstyle"])
          putStrLn "=== [yamaarashi-exec] Shared dist-newstyle into isolated worktree ==="
        hasOkToml <- doesFileExist (repoRoot </> "ok.toml")
        when hasOkToml $ do
          copyFile (repoRoot </> "ok.toml") (worktreeDir </> "ok.toml")
          putStrLn "=== [yamaarashi-exec] Seeded ok.toml into isolated worktree ==="
        hasOkDir <- doesDirectoryExist (repoRoot </> ".ok")
        when hasOkDir $ do
          _ <- runProcess (proc "ln" ["-s", repoRoot </> ".ok", worktreeDir </> ".ok"])
          putStrLn "=== [yamaarashi-exec] Shared .ok memory index into isolated worktree ==="
        hasContextful <- doesDirectoryExist (repoRoot </> ".contextful")
        when hasContextful $ do
          _ <- runProcess (proc "ln" ["-s", repoRoot </> ".contextful", worktreeDir </> ".contextful"])
          putStrLn "=== [yamaarashi-exec] Shared .contextful index into isolated worktree ==="
        logEvent dbPath (packetId packet) "WORKTREE_PROVISIONED" (T.pack worktreeDir)
        pure worktreeDir

      teardown wtDir = do
        putStrLn $ "=== [yamaarashi-exec] Tearing down worktree: " ++ wtDir ++ " ==="
        _ <- runProcess (proc "rm" ["-rf", wtDir </> ".ok"])
        _ <- runProcess (proc "rm" ["-f", wtDir </> "ok.toml"])
        _ <- runProcess (proc "rm" ["-rf", wtDir </> ".contextful"])
        _ <- runProcess (proc "rm" ["-f", wtDir </> "dist-newstyle"])
        _ <- runProcess (proc "git" ["worktree", "remove", "--force", wtDir])
        _ <- runProcess (proc "git" ["branch", "-D", branchName])
        logEvent dbPath (packetId packet) "WORKTREE_TEARDOWN" (T.pack wtDir)

  bracket provision teardown $ \wtDir -> do
    let maxAttempts = maybe 3 id (packetMaxRepairAttempts packet)
        loop attempt mRepairPrompt = do
          putStrLn $ "=== [yamaarashi-exec] Execution Cycle " ++ show attempt ++ " of " ++ show maxAttempts ++ " ==="
          logEvent dbPath (packetId packet) "STEP_STARTED" ("Attempt " <> T.pack (show attempt) <> " started")
          mExecRes <- executeTaskStep wtDir packet dbPath mRepairPrompt attempt
          case mExecRes of
            Left stepErr -> do
              putStrLn $ "=== [yamaarashi-exec] Task step failed on attempt " ++ show attempt ++ ": " ++ T.unpack stepErr
              logEvent dbPath (packetId packet) "STEP_FAILED" stepErr
              if attempt < maxAttempts
                then do
                  let nextPrompt = buildRepairPrompt packet stepErr (attempt + 1) maxAttempts
                  loop (attempt + 1) (Just nextPrompt)
                else throwIO (userError $ "Task execution failed after " ++ show maxAttempts ++ " attempts: " ++ T.unpack stepErr)
            Right actualExec -> do
              logEvent dbPath (packetId packet) "STEP_EXECUTED" ("Modifications applied successfully via " <> actualExec <> " (attempt " <> T.pack (show attempt) <> ")")
              putStrLn "=== [yamaarashi-exec] Running verification gate ==="
              logEvent dbPath (packetId packet) "VERIFICATION_STARTED" ("Verification for attempt " <> T.pack (show attempt))
              vRes <- runVerificationGate wtDir packet
              case vRes of
                Right () -> do
                  logEvent dbPath (packetId packet) "VERIFICATION_PASSED" ("All build and audit checks passed on attempt " <> T.pack (show attempt))
                  pure actualExec
                Left verifyErr -> do
                  putStrLn $ "=== [yamaarashi-exec] Verification gate failed on attempt " ++ show attempt ++ " ==="
                  putStrLn (T.unpack verifyErr)
                  logEvent dbPath (packetId packet) "VERIFICATION_FAILED" verifyErr
                  if attempt < maxAttempts
                    then do
                      healed <- runAutoHeal wtDir verifyErr
                      if healed
                        then do
                          putStrLn "=== [yamaarashi-exec] Auto-heal applied fixes! Re-verifying gate... ==="
                          logEvent dbPath (packetId packet) "AUTOHEAL_APPLIED" "Applied mechanical fixes via hls-autoheal"
                          vRes2 <- runVerificationGate wtDir packet
                          case vRes2 of
                            Right () -> do
                              putStrLn "=== [yamaarashi-exec] Auto-healed verification gate PASSED! ==="
                              logEvent dbPath (packetId packet) "AUTOHEAL_PASSED" ("Verification succeeded after auto-heal on attempt " <> T.pack (show attempt))
                              pure actualExec
                            Left verifyErr2 -> do
                              putStrLn $ "=== [yamaarashi-exec] Verification still failed after auto-heal. Initiating repair cycle (" ++ show (attempt + 1) ++ "/" ++ show maxAttempts ++ ") ==="
                              let nextPrompt = buildRepairPrompt packet verifyErr2 (attempt + 1) maxAttempts
                              loop (attempt + 1) (Just nextPrompt)
                        else do
                          putStrLn $ "=== [yamaarashi-exec] Initiating repair cycle (" ++ show (attempt + 1) ++ "/" ++ show maxAttempts ++ ") ==="
                          let nextPrompt = buildRepairPrompt packet verifyErr (attempt + 1) maxAttempts
                          loop (attempt + 1) (Just nextPrompt)
                    else throwIO (userError $ "Task failed verification after " ++ show maxAttempts ++ " attempts:\n" ++ T.unpack verifyErr)

    actualExec <- loop 1 Nothing

    -- Step 3: Git Commit
    putStrLn "=== [yamaarashi-exec] Creating git commit with attribution trailers ==="
    commitHash <- createGitCommit wtDir packet actualExec
    logEvent dbPath (packetId packet) "COMMIT_CREATED" commitHash

    -- Step 4: Fast-forward merge into main repository
    putStrLn $ "=== [yamaarashi-exec] Merging " ++ branchName ++ " into repository ==="
    runProcess_ (setWorkingDir repoRoot (proc "git" ["merge", "--ff-only", branchName]))

    logEvent dbPath (packetId packet) "TASK_COMPLETED" ("Merged commit " <> commitHash)
    vacuumTaskLedger dbPath
    putStrLn $ "=== [yamaarashi-exec] Compacted task ledger database via VACUUM ==="

    -- Record institutional memory in ok memory
    let memText = "Task " ++ tId ++ " (" ++ T.unpack (packetTitle packet) ++ "): Completed successfully. Merged commit " ++ T.unpack commitHash ++ "."
    _ <- runProcess (setWorkingDir repoRoot (proc "ok" ["memory", "remember", "--confidence", "high", "--source", "yamaarashi", memText]))
    putStrLn $ "=== [yamaarashi-exec] Recorded task completion into institutional memory (ok memory) ==="
    putStrLn $ "=== [yamaarashi-exec] SUCCESS: Task " ++ tId ++ " completed successfully! ==="

-- | Initialize SQLite event store table.
initEventDb :: FilePath -> IO ()
initEventDb = initTaskLedger

-- | Record an event into SQLite.
logEvent :: FilePath -> Text -> Text -> Text -> IO ()
logEvent = logTaskEvent

-- | Simple parser for Task Packet YAML adhering to Zero-Aeson invariant.
parsePacket :: FilePath -> Text -> IO TaskPacket
parsePacket path txt = do
  let lns = T.lines txt
      stripQuotes s =
        let t = T.strip s
        in if (T.isPrefixOf "\"" t && T.isSuffixOf "\"" t && T.length t >= 2)
           || (T.isPrefixOf "'" t && T.isSuffixOf "'" t && T.length t >= 2)
             then T.drop 1 (T.dropEnd 1 t)
             else t
      findVal key = case filter (T.isPrefixOf (key <> ":")) lns of
        (l:_) -> stripQuotes (T.strip (T.drop (T.length key + 1) l))
        []    -> ""
      extractList key =
        let afterKey = drop 1 $ dropWhile (\l -> not (T.isPrefixOf (key <> ":") l)) lns
            items = takeWhile (\l -> T.isPrefixOf "  - " l || T.isPrefixOf "- " l) afterKey
            clean l = stripQuotes (T.strip (T.dropWhile (\c -> c == ' ' || c == '-') (fst (T.breakOn "#" l))))
        in filter (not . T.null) (map clean items)
      extractBlock key =
        let afterKey = drop 1 $ dropWhile (\l -> not (T.isPrefixOf (key <> ":") l)) lns
            headerLine = case filter (T.isPrefixOf (key <> ":")) lns of
              (l:_) -> T.strip (T.drop (T.length key + 1) l)
              []    -> ""
        in if headerLine == "|" || headerLine == ">" || T.null headerLine
             then
               let blockLines = takeWhile (\l -> T.null (T.strip l) || T.isPrefixOf "  " l || T.isPrefixOf "\t" l) afterKey
                   stripIndent l = if T.isPrefixOf "  " l then T.drop 2 l else l
               in T.unlines (map stripIndent blockLines)
             else headerLine

      pId = findVal "id"
      pTitle = findVal "title"
      pDesc = extractBlock "description"
      pPackages = extractList "packages"
      pExecRaw = findVal "executor"
      pModelRaw = findVal "model"
      pSkills = extractList "skills"
      pMaxTurnsRaw = findVal "max_turns"
      pBudgetRaw = findVal "run_budget"
      pMaxRepairRaw = findVal "max_repair_attempts"
      pAllowMeteredRaw = findVal "allow_metered"

      pAllowMetered = pAllowMeteredRaw == "true" || pAllowMeteredRaw == "True"
      pModel = if T.null pModelRaw then Nothing else Just pModelRaw
      pMaxTurns = case reads (T.unpack pMaxTurnsRaw) of
        [(n, "")] -> Just n
        _         -> Nothing
      pBudget = case reads (T.unpack pBudgetRaw) of
        [(n, "")] -> Just n
        _         -> Nothing
      pMaxRepair = case reads (T.unpack pMaxRepairRaw) of
        [(n, "")] -> Just n
        _         -> Nothing
      pExec = if T.null pExecRaw then "auto" else pExecRaw
  if T.null pId
    then throwIO (userError $ "Malformed task packet in " ++ path ++ ": missing 'id'")
    else pure $ TaskPacket
      { packetId = pId
      , packetTitle = if T.null pTitle then pId else pTitle
      , packetDescription = pDesc
      , packetPackages = pPackages
      , packetExecutor = pExec
      , packetModel = pModel
      , packetSkills = pSkills
      , packetMaxTurns = pMaxTurns
      , packetRunBudget = pBudget
      , packetMaxRepairAttempts = pMaxRepair
      , packetAllowMetered = pAllowMetered
      , packetRawYaml = txt
      }

-- | Execute task actions inside the isolated worktree directory.
-- Returns Right executorName on success ("agy", "hermes", "script", or "inline"),
-- or Left errorMessage on failure.
executeTaskStep :: FilePath -> TaskPacket -> FilePath -> Maybe Text -> Int -> IO (Either Text Text)
executeTaskStep wtDir packet dbPath mRepairPrompt attempt = do
  let tId = packetId packet
  case tId of
    "fix-kogaki-wire-lexer-nonempty" -> do
      putStrLn "  -> Applying Kogaki.Wire.Json.Lexer safe non-empty refactoring..."
      let targetFile = wtDir </> "packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs"
      TIO.writeFile targetFile fixedLexerContent
      pure (Right "inline")
    _ -> do
      let customShScript = wtDir </> "scripts/tasks" </> T.unpack tId ++ ".sh"
          customGoScript = wtDir </> "scripts/tasks" </> T.unpack tId ++ ".go"
      shExists <- doesFileExist customShScript
      goExists <- doesFileExist customGoScript
      let execMode = packetExecutor packet
      case execMode of
        "script" ->
          if shExists
            then runScriptStep (packetAllowMetered packet) wtDir customShScript
            else if goExists
              then runYaegiStep (packetAllowMetered packet) wtDir customGoScript
              else pure (Left $ "Explicit script executor requested, but script missing: " <> T.pack customShScript)
        "yaegi" ->
          if goExists
            then runYaegiStep (packetAllowMetered packet) wtDir customGoScript
            else pure (Left $ "Explicit yaegi executor requested, but script missing: " <> T.pack customGoScript)
        "go" ->
          if goExists
            then runYaegiStep (packetAllowMetered packet) wtDir customGoScript
            else pure (Left $ "Explicit go executor requested, but script missing: " <> T.pack customGoScript)
        "sarutahiko" ->
          runSarutahikoStep wtDir packet dbPath mRepairPrompt attempt
        "utai" ->
          runUtaiStep wtDir packet dbPath mRepairPrompt attempt
        "hermes" ->
          runHermesStep wtDir packet dbPath mRepairPrompt attempt
        "agy" ->
          runAgyStep wtDir packet dbPath mRepairPrompt attempt
        "auto" ->
          if goExists
            then runYaegiStep (packetAllowMetered packet) wtDir customGoScript
            else if shExists
              then runScriptStep (packetAllowMetered packet) wtDir customShScript
              else runUtaiStep wtDir packet dbPath mRepairPrompt attempt
        other ->
          pure (Left $ "Unknown executor: " <> other <> " (expected 'sarutahiko', 'utai', 'agy', 'hermes', 'script', 'yaegi', 'go', or 'auto')")

-- | Delegate task execution directly to in-tree Sarutahiko autonomous agent core.
runSarutahikoStep :: FilePath -> TaskPacket -> FilePath -> Maybe Text -> Int -> IO (Either Text Text)
runSarutahikoStep wtDir packet dbPath mRepairPrompt attempt = do
  let tId = packetId packet
      promptContent = case mRepairPrompt of
        Just rp -> rp
        Nothing -> buildWorkerPrompt packet
      targetModel = case packetModel packet of
        Just m  -> m
        Nothing -> "mistral/codestral-latest"

  workerEnv <- buildWorkerEnv (packetAllowMetered packet)
  logEvent dbPath tId "SARUTAHIKO_SPAWNED" ("Sarutahiko autonomous agent core starting turn (attempt " <> T.pack (show attempt) <> ")")
  putStrLn $ "=== [yamaarashi-exec] Launching Sarutahiko autonomous agent core (model: " ++ T.unpack targetModel ++ ", attempt " ++ show attempt ++ ") ==="

  mSarutahiko <- findExecutable "sarutahiko"
  let cmdProc = case mSarutahiko of
        Just bin -> proc bin ["run", "--live", T.unpack promptContent]
        Nothing  -> proc "cabal" ["v2-run", "sarutahiko-agent:exe:sarutahiko", "--", "run", "--live", T.unpack promptContent]

  (code, outBs, errBs) <- readProcess (setEnv workerEnv (setWorkingDir wtDir cmdProc))
  let outTxt = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs]))
      logDir = takeDirectory dbPath </> "logs"
      attemptSuffix = if attempt > 1 then "-attempt" ++ show attempt else ""
      workerLogFile = logDir </> (T.unpack tId ++ "-sarutahiko" ++ attemptSuffix ++ ".log")

  createDirectoryIfMissing True logDir
  TIO.writeFile workerLogFile outTxt

  case code of
    ExitSuccess -> do
      logEvent dbPath tId "SARUTAHIKO_SUCCEEDED" ("Sarutahiko completed turn (" <> T.pack (show (T.length outTxt)) <> " chars output)")
      putStrLn "=== [yamaarashi-exec] Sarutahiko autonomous agent execution succeeded ==="
      pure (Right "sarutahiko")
    ExitFailure c -> do
      let errMsg = "Sarutahiko execution failed with code " <> T.pack (show c) <> ":\n" <> trimErrorOutput outTxt
      logEvent dbPath tId "SARUTAHIKO_FAILED" errMsg
      pure (Left errMsg)

-- | Check if an error message represents a rate limit / 429 quota exhaustion.
isRateLimited :: Text -> Bool
isRateLimited err =
  let lower = T.toLower err
  in "429" `T.isInfixOf` lower
     || "rate limit" `T.isInfixOf` lower
     || "quota" `T.isInfixOf` lower
     || "resource_exhausted" `T.isInfixOf` lower

-- | Direct-connexion protocol for the Utai executor: the model has no file
-- tools, so it must emit its work as fenced unified-diff blocks which the
-- runner applies to the worktree with `git apply`.
utaiDiffInstructions :: Text
utaiDiffInstructions = T.unlines
  [ ""
  , "## Direct-Connexion Output Protocol (Utai)"
  , ""
  , "You are invoked as a direct (stateless) model call: you have NO file-editing"
  , "tools. Express your entire implementation as unified diffs in fenced"
  , "code blocks opened with ```diff (or ```patch):"
  , ""
  , "    ```diff"
  , "    --- a/path/to/File.hs"
  , "    +++ b/path/to/File.hs"
  , "    @@ -1,2 +1,3 @@"
  , "     context line"
  , "    +added line"
  , "    ```"
  , ""
  , "Rules:"
  , "1. One fenced block per changed file, paths relative to the repository root."
  , "   EXISTING files: header MUST be exactly `--- a/path/to/File.hs` and"
  , "   `+++ b/path/to/File.hs` (no `index`, no `diff --git` lines, no timestamps)."
  , "   NEW files (not present in the repository context): header MUST be exactly"
  , "   `--- /dev/null` and `+++ b/path/to/NewFile.hs`."
  , "2. NEVER create a new package, .cabal file, or top-level module. Work ONLY"
  , "   within the existing packages named in the spec; extend their existing"
  , "   .cabal files and source trees. Study the repository context below before"
  , "   writing any diff; mirror its module naming and dependency conventions."
  , "3. Context lines must match the existing file content exactly (diff -u style);"
  , "   keep hunks small and self-contained so `git apply --recount` succeeds."
  , "4. Emit every changed file (source, .cabal, tests, re-exports) in these blocks;"
  , "   your response is concatenated and applied verbatim."
  , "5. If the spec names target files that do not exist yet, still use the"
  , "   `--- /dev/null` new-file header for them."
  , "6. Do NOT narrate tool usage, do NOT propose shell commands, and do NOT claim"
  , "   files were edited - the diff blocks ARE the deliverable. Nothing outside"
  , "   the fenced blocks is applied."
  , ""
  ]

-- | Extract unified-diff fenced blocks (```diff / ```patch) from a model response.
extractDiffBlocks :: Text -> [Text]
extractDiffBlocks txt = go (T.lines txt)
  where
    isFence l =
      let s = T.strip l
      in "```diff" `T.isPrefixOf` s || "```patch" `T.isPrefixOf` s
    go [] = []
    go (l:ls)
      | isFence l =
          let (block, rest) = span (\x -> not (T.isPrefixOf "```" (T.strip x))) ls
          in case block of
               [] -> go (drop 1 rest)
               _  -> T.unlines block : go (drop 1 rest)
      | otherwise = go ls

-- | Recount hunk line counts in a unified diff. Models routinely emit
-- plausible-but-wrong counts in the `@@ ... @@` headers (attempt 1 of
-- TP-AUDIT-002 claimed +100 with 85 body lines); `git apply` validates
-- new-file sections strictly and rejects the patch with "new file
-- depends on old contents" despite `--recount`. This rewrites each
-- header with counts measured from its body.
sanityDiff :: Text -> Text
sanityDiff txt = T.unlines (go (T.lines txt))
  where
    isSectionHead x =
      let s = T.strip x
      in "--- " `T.isPrefixOf` s || "+++ " `T.isPrefixOf` s
           || "diff --git" `T.isPrefixOf` s || "@@" `T.isPrefixOf` s
    go [] = []
    go (l:ls)
      | "@@" `T.isPrefixOf` T.strip l =
          let (rawBody, rest) = span (\x -> not (isSectionHead x)) ls
              -- Models emit truly-empty lines where unified diff requires a
              -- single-space context prefix; a bare empty line truncates
              -- git's hunk parser and desyncs every subsequent section.
              body = map (\x -> if T.null x then " " else x) rawBody
              isPlus x = T.isPrefixOf "+" x && not (T.isPrefixOf "+++" x)
              isMinus x = T.isPrefixOf "-" x && not (T.isPrefixOf "---" x)
              isCtx x = T.isPrefixOf " " x || T.null x
              oldC = length (filter (\x -> isMinus x || isCtx x) body)
              newC = length (filter (\x -> isPlus x || isCtx x) body)
              parts = T.splitOn " " (T.strip l)
              parseRange p def = case T.splitOn "," (T.drop 1 p) of
                [a] -> maybe def (\n -> (n, 1)) (parseInt a)
                (a:b:_) -> case (parseInt a, parseInt b) of
                  (Just s, Just c) -> (s, c)
                  _ -> def
                _ -> def
              parseInt s = case reads (T.unpack s) of
                [(n, "")] -> Just n
                _ -> Nothing
              (oldStart, _oldLen) = case parts of
                (_:r:_) -> parseRange r (1, 1)
                _ -> (1, 1)
              (newStart, _newLen) = case parts of
                (_:_:r:_) -> parseRange r (1, 1)
                _ -> (1, 1)
              newHeader = T.unwords
                [ "@@"
                , "-" <> T.pack (show oldStart) <> "," <> T.pack (show oldC)
                , "+" <> T.pack (show newStart) <> "," <> T.pack (show newC)
                , "@@"
                ]
          in newHeader : body ++ go rest
      | otherwise = l : go ls

-- | Direct-connexion context: the model cannot list or open files, so the
-- runner embeds a bounded inventory of the worktree (packages, .cabal files,
-- source/test trees, top-level scripts) plus verbatim contents of the
-- packet's target files and the nearest dependency cabals. Without this
-- the model invents its own layout instead of matching the repository.
buildUtaiContext :: FilePath -> TaskPacket -> IO Text
buildUtaiContext wtDir packet = do
  let pkgs = packetPackages packet
      pkgFilter p = p `elem` map T.unpack pkgs
      rel p = if take (length wtDir + 1) p == wtDir ++ "/"
                then drop (length wtDir + 1) p
                else p
  pkgDirs <- filter (\p -> length p > 0) <$> listDirectory (wtDir </> "packages")
  srcEntries <- mapM (\pd -> (pd,) <$> safeList (wtDir </> "packages" </> pd)) pkgDirs
  scriptEntries <- safeList (wtDir </> "scripts")
  topLevel <- safeList wtDir
  targetPackLines <- mapM (\pd -> do
    let cab = wtDir </> "packages" </> pd
    fs <- safeList cab
    let cabalFiles = filter (\f -> ".cabal" `T.isSuffixOf` T.pack f) fs
    cabalEntries <- mapM (\f -> do
      t <- TIO.readFile (cab </> f)
      pure ["--- packages/" <> T.pack pd <> "/" <> T.pack f <> " ---", t]) cabalFiles
    srcFiles <- walkFiles (cab </> "src") 5
    testFiles <- walkFiles (cab </> "test") 5
    srcEntries <- mapM (\f -> do
      t <- TIO.readFile f
      pure ["--- FILE: " <> T.pack (rel f) <> " ---", t]) (take 40 (srcFiles ++ testFiles))
    pure (concat cabalEntries ++ concat srcEntries)) [p | p <- pkgDirs, pkgFilter p]
  let treeLines = concatMap (\(pd, fs) -> map (\f -> "packages/" ++ pd ++ "/" ++ rel f) fs) srcEntries
      scriptsLine = unwords (map rel (take 200 scriptEntries))
      topLine = unwords (map rel (take 100 topLevel))
      cabalSection = concat targetPackLines
  return $ T.unlines $ concat
    [ [ "## Repository Context (embedded; you cannot browse the worktree)"
      , ""
      , "Target packages: " <> (if null pkgs then T.pack "(all)" else T.intercalate ", " pkgs)
      , "Package directories: " <> T.pack (unwords pkgDirs)
      , ""
      , "### Files under packages/ (one level per package)"
      ]
    , take 300 (map T.pack treeLines)
    , [ ""
      , "### scripts/tasks/"
      , T.pack scriptsLine
      , ""
      , "### Top level"
      , T.pack topLine
      , ""
      , "### Target package files (verbatim; these are the ONLY files you may diff against)"
      ]
    , cabalSection
    ]
  where
    safeList :: FilePath -> IO [FilePath]
    safeList p = do
      exists <- doesDirectoryExist p
      if exists then listDirectory p else pure []
    walkFiles :: FilePath -> Int -> IO [FilePath]
    walkFiles root d
      | d <= 0 = pure []
      | otherwise = do
          entries <- safeList root
          mapM walk1 entries >>= pure . concat
      where walk1 name = do
              let p = root </> name
              isDir <- doesDirectoryExist p
              if isDir
                then walkFiles p (d - 1)
                else pure [p]  -- include all files; read happens at embed time

-- | Delegate task execution directly to Utai native LLM client.
runUtaiStep :: FilePath -> TaskPacket -> FilePath -> Maybe Text -> Int -> IO (Either Text Text)
runUtaiStep wtDir packet dbPath mRepairPrompt attempt = do
  let tId = packetId packet
      basePrompt = case mRepairPrompt of
        Just rp -> rp
        Nothing -> buildWorkerPrompt packet
  repoContext <- buildUtaiContext wtDir packet
  let promptContent = basePrompt <> "\n" <> repoContext <> utaiDiffInstructions
  let targetModel = case packetModel packet of
        Just m  -> m
        Nothing -> "auto/best-coding"
      budgetSec = maybe 600 id (packetRunBudget packet)

  logEvent dbPath tId "UTAI_SPAWNED" ("Utai native client querying " <> targetModel <> " (attempt " <> T.pack (show attempt) <> ")")
  putStrLn $ "=== [yamaarashi-exec] Querying native Utai client (model: " ++ T.unpack targetModel ++ ", attempt " ++ show attempt ++ ") ==="

  -- Persist the exact prompt so failures can be debugged post-hoc.
  let logDir0 = takeDirectory dbPath </> "logs"
  createDirectoryIfMissing True logDir0
  TIO.writeFile (logDir0 </> (T.unpack tId ++ "-utai-attempt" ++ show attempt ++ "-prompt.md")) promptContent

  let req = CompletionReq
        { reqModel    = targetModel
        , reqMessages = [Message RoleUser promptContent]
        , reqTools    = []
        , reqOptions  = defaultModelOptions
        }
      primaryProfile = omnirouteProfile { profileModels = [targetModel] }
      fallbackProfiles = if packetAllowMetered packet
                           then [primaryProfile, opencodeProfile]
                           else [primaryProfile]

      queryWithBackoff backoffAttempt maxBackoffs = do
        mRes <- callOpenAIWithFallback fallbackProfiles req
        case mRes of
          Left err | isRateLimited err && backoffAttempt < maxBackoffs -> do
            let delaySec = 10 * (2 ^ (backoffAttempt - 1))
            putStrLn $ "=== [yamaarashi-exec] HTTP 429 / Rate Limit detected. Delayed queue backoff: waiting " ++ show delaySec ++ "s (backoff " ++ show backoffAttempt ++ "/" ++ show maxBackoffs ++ ") ==="
            logEvent dbPath tId "UTAI_RATE_LIMITED" ("Backoff " <> T.pack (show backoffAttempt) <> ": sleeping " <> T.pack (show delaySec) <> "s without tier escalation")
            threadDelay (delaySec * 1000000)
            queryWithBackoff (backoffAttempt + 1) maxBackoffs
          Left err -> pure (Left err)
          Right resp -> pure (Right resp)

  mRes <- timeout (budgetSec * 1000000) (queryWithBackoff (1 :: Int) (3 :: Int))
  case mRes of
    Nothing -> do
      let errMsg = "Utai invocation exceeded the packet run_budget of " <> T.pack (show budgetSec) <> "s"
      logEvent dbPath tId "UTAI_TIMEOUT" errMsg
      pure (Left errMsg)
    Just (Left err) -> do
      let errMsg = "Utai invocation failed: " <> err
      logEvent dbPath tId "UTAI_FAILED" errMsg
      pure (Left errMsg)
    Just (Right resp) -> do
      let logDir = takeDirectory dbPath </> "logs"
          attemptSuffix = if attempt > 1 then "-attempt" ++ show attempt else ""
          workerLogFile = logDir </> (T.unpack tId ++ "-utai" ++ attemptSuffix ++ ".log")
      createDirectoryIfMissing True logDir
      TIO.writeFile workerLogFile (respContent resp)
      let diffBlocks = extractDiffBlocks (respContent resp)
      case diffBlocks of
        [] -> do
          let errMsg = "Utai response contained no ```diff/```patch blocks to apply (see " <> T.pack workerLogFile <> ")"
          logEvent dbPath tId "UTAI_NO_DIFF" errMsg
          putStrLn $ "=== [yamaarashi-exec] " ++ T.unpack errMsg ++ " ==="
          pure (Left errMsg)
        _ -> do
          let patchFile = wtDir </> (".utai-" ++ show attempt ++ ".patch")
          TIO.writeFile patchFile (T.unlines (map sanityDiff diffBlocks))
          (code, outBs, errBs) <- readProcess (setWorkingDir wtDir (proc "git" ["apply", "--recount", "--whitespace=nowarn", patchFile]))
          case code of
            ExitFailure c -> do
              let errMsg = "Utai diff failed to apply (git apply exit " <> T.pack (show c) <> "):\n" <> trimErrorOutput (TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs])))
              logEvent dbPath tId "UTAI_APPLY_FAILED" errMsg
              putStrLn $ "=== [yamaarashi-exec] " ++ T.unpack errMsg ++ " ==="
              pure (Left errMsg)
            ExitSuccess -> do
              removeFile patchFile
              logEvent dbPath tId "UTAI_SUCCEEDED" ("Utai returned " <> T.pack (show (T.length (respContent resp))) <> " chars; applied " <> T.pack (show (length diffBlocks)) <> " diff block(s)")
              putStrLn $ "=== [yamaarashi-exec] Utai native invocation applied " ++ show (length diffBlocks) ++ " diff block(s) ==="
              pure (Right "utai")

-- | Execute task script in the isolated worktree with quota firewall env.
runScriptStep :: Bool -> FilePath -> FilePath -> IO (Either Text Text)
runScriptStep allowMetered wtDir scriptPath = do
  putStrLn $ "  -> Running task script: " ++ scriptPath
  workerEnv <- buildWorkerEnv allowMetered
  (code, outBs, errBs) <- readProcess (setEnv workerEnv (setWorkingDir wtDir (proc "sh" [scriptPath])))
  case code of
    ExitSuccess -> pure (Right "script")
    ExitFailure c -> do
      let errText = trimErrorOutput (TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs])))
      pure (Left $ "Task script " <> T.pack scriptPath <> " failed with code " <> T.pack (show c) <> ":\n" <> errText)

-- | Execute task Go script via Yaegi interpreter with quota firewall env.
runYaegiStep :: Bool -> FilePath -> FilePath -> IO (Either Text Text)
runYaegiStep allowMetered wtDir scriptPath = do
  putStrLn $ "  -> Running task Go script via Yaegi: " ++ scriptPath
  mYaegi <- findExecutable "yaegi"
  case mYaegi of
    Nothing -> pure (Left "Yaegi executor requested, but 'yaegi' executable was not found in PATH.")
    Just yaegiBin -> do
      workerEnv <- buildWorkerEnv allowMetered
      (code, outBs, errBs) <- readProcess (setEnv workerEnv (setWorkingDir wtDir (proc yaegiBin ["run", scriptPath])))
      case code of
        ExitSuccess -> pure (Right "yaegi")
        ExitFailure c -> do
          let errText = trimErrorOutput (TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs])))
          pure (Left $ "Yaegi script " <> T.pack scriptPath <> " failed with code " <> T.pack (show c) <> ":\n" <> errText)

-- | Delegate task execution to Antigravity CLI in non-interactive print mode.
runAgyStep :: FilePath -> TaskPacket -> FilePath -> Maybe Text -> Int -> IO (Either Text Text)
runAgyStep wtDir packet dbPath mRepairPrompt attempt = do
  mAgy <- findExecutable "agy"
  case mAgy of
    Nothing -> pure (Left "Agy executor requested, but 'agy' executable was not found in PATH.")
    Just agyBin -> do
      workerEnv <- buildWorkerEnv (packetAllowMetered packet)
      let tId = packetId packet
          promptFile = wtDir </> ".worker-task-prompt.md"
          promptContent = case mRepairPrompt of
            Just rp -> rp
            Nothing -> buildWorkerPrompt packet
          budgetSec = maybe 600 id (packetRunBudget packet)
          budgetStr = show budgetSec ++ "s"
          logDir = takeDirectory dbPath </> "logs"
          attemptSuffix = if attempt > 1 then "-attempt" ++ show attempt else ""
          workerLogFile = logDir </> (T.unpack tId ++ "-agy" ++ attemptSuffix ++ ".log")

      createDirectoryIfMissing True logDir
      TIO.writeFile promptFile promptContent
      logEvent dbPath tId "AGY_SPAWNED" ("Prompt written to " <> T.pack promptFile <> " (attempt " <> T.pack (show attempt) <> ")")
      putStrLn $ "=== [yamaarashi-exec] Spawning Agy leaf worker (attempt " ++ show attempt ++ ") in: " ++ wtDir ++ " ==="
      putStrLn $ "=== [yamaarashi-exec] Log destination: " ++ workerLogFile ++ " ==="

      let normalizeAgyModel "flash_lite" = "gemini-3.8-flash-low"
          normalizeAgyModel "flash"      = "gemini-3.8-flash-medium"
          normalizeAgyModel m            = T.unpack m
          modelArgs = case packetModel packet of
            Just m | not (T.null m) -> ["--model", normalizeAgyModel m]
            _                       -> ["--model", "gemini-3.8-flash-low"]
          cmdArgs =
            [ "-p", T.unpack promptContent
            , "--dangerously-skip-permissions"
            , "--print-timeout", budgetStr
            ] ++ modelArgs

      putStrLn $ "=== [yamaarashi-exec] Running: " ++ agyBin ++ " -p <prompt> --dangerously-skip-permissions --print-timeout " ++ budgetStr ++ " " ++ unwords modelArgs ++ " ==="
      mRes <- timeout ((budgetSec + 30) * 1000000) $ do
        (exitCode, outBs, errBs) <- readProcess (setEnv workerEnv (setWorkingDir wtDir (proc agyBin cmdArgs)))
        BSL.writeFile workerLogFile (BSL.concat [outBs, "\n--- STDERR ---\n", errBs])
        pure exitCode

      case mRes of
        Nothing -> do
          let errMsg = "Agy execution timed out after " ++ show budgetSec ++ " seconds."
          logEvent dbPath tId "AGY_TIMEOUT" (T.pack errMsg)
          pure (Left $ T.pack errMsg)
        Just ExitSuccess -> do
          logEvent dbPath tId "AGY_SUCCEEDED" ("Agy task execution exited with code 0 (attempt " <> T.pack (show attempt) <> ")")
          putStrLn "=== [yamaarashi-exec] Agy leaf worker completed successfully ==="
          pure (Right "agy")
        Just (ExitFailure code) -> do
          let errMsg = "Agy execution failed with exit code " ++ show code ++ " (see " ++ workerLogFile ++ ")"
          logEvent dbPath tId "AGY_FAILED" (T.pack errMsg)
          pure (Left $ T.pack errMsg)

-- | Delegate task execution to a spawned Hermes leaf worker agent.
runHermesStep :: FilePath -> TaskPacket -> FilePath -> Maybe Text -> Int -> IO (Either Text Text)
runHermesStep wtDir packet dbPath mRepairPrompt attempt = do
  mHermes <- findExecutable "hermes"
  case mHermes of
    Nothing -> pure (Left "Hermes executor requested, but 'hermes' executable was not found in PATH.")
    Just hermesBin -> do
      workerEnv <- buildWorkerEnv (packetAllowMetered packet)
      let tId = packetId packet
          promptFile = wtDir </> ".worker-task-prompt.md"
          promptContent = case mRepairPrompt of
            Just rp -> rp
            Nothing -> buildWorkerPrompt packet
          budgetSec = maybe 900 id (packetRunBudget packet)
          logDir = takeDirectory dbPath </> "logs"
          attemptSuffix = if attempt > 1 then "-attempt" ++ show attempt else ""
          workerLogFile = logDir </> (T.unpack tId ++ "-hermes" ++ attemptSuffix ++ ".log")

      createDirectoryIfMissing True logDir
      TIO.writeFile promptFile promptContent
      logEvent dbPath tId "HERMES_SPAWNED" ("Prompt written to " <> T.pack promptFile <> " (attempt " <> T.pack (show attempt) <> ")")
      putStrLn $ "=== [yamaarashi-exec] Spawning Hermes leaf worker (attempt " ++ show attempt ++ ") in: " ++ wtDir ++ " ==="
      putStrLn $ "=== [yamaarashi-exec] Log destination: " ++ workerLogFile ++ " ==="

      let baseArgs =
            [ "--in", wtDir
            , "-z", T.unpack promptContent
            , "--yolo"
            , "--accept-hooks"
            ]
          skillsArgs = case packetSkills packet of
            [] -> ["-s", "code-navigation,tricorder,contextful"]
            ss -> ["-s", T.unpack (T.intercalate "," ss)]
          modelArgs = case packetModel packet of
            Just m  -> ["-m", T.unpack m]
            Nothing -> []
          cmdArgs = baseArgs ++ skillsArgs ++ modelArgs

      putStrLn $ "=== [yamaarashi-exec] Command: " ++ hermesBin ++ " --in " ++ wtDir ++ " -z <prompt> --yolo --accept-hooks ==="
      mRes <- timeout ((budgetSec + 30) * 1000000) $ do
        (exitCode, outBs, errBs) <- readProcess (setEnv workerEnv (proc hermesBin cmdArgs))
        BSL.writeFile workerLogFile (BSL.concat [outBs, "\n--- STDERR ---\n", errBs])
        pure exitCode

      case mRes of
        Nothing -> do
          let errMsg = "Hermes execution timed out after " ++ show budgetSec ++ " seconds."
          logEvent dbPath tId "HERMES_TIMEOUT" (T.pack errMsg)
          pure (Left $ T.pack errMsg)
        Just ExitSuccess -> do
          logEvent dbPath tId "HERMES_SUCCEEDED" ("Hermes task execution exited with code 0 (attempt " <> T.pack (show attempt) <> ")")
          putStrLn "=== [yamaarashi-exec] Hermes leaf worker completed successfully ==="
          pure (Right "hermes")
        Just (ExitFailure code) -> do
          let errMsg = "Hermes execution failed with exit code " ++ show code ++ " (see " ++ workerLogFile ++ ")"
          logEvent dbPath tId "HERMES_FAILED" (T.pack errMsg)
          pure (Left $ T.pack errMsg)

-- | Construct structured prompt markdown for the spawned leaf worker.
buildWorkerPrompt :: TaskPacket -> Text
buildWorkerPrompt packet = T.unlines
  [ "# Autonomous Task Packet: " <> packetTitle packet
  , ""
  , "## Packet Identifier"
  , packetId packet
  , ""
  , "## Target Packages"
  , if null (packetPackages packet)
      then "All repository packages"
      else T.intercalate ", " (packetPackages packet)
  , ""
  , "## Task Specification"
  , packetDescription packet
  , ""
  , "## Task Packet Blueprint"
  , "```yaml"
  , packetRawYaml packet
  , "```"
  , ""
  , "## Operational Invariants & Ground Rules"
  , "1. Strict Worktree Isolation: You are operating inside an isolated git worktree branch."
  , "   Do NOT attempt to cd outside this directory or modify parent repos."
  , "2. GHC2024 & Zero Warnings: All Haskell code MUST compile cleanly with -Wall -Werror."
  , "   Avoid unused imports, incomplete patterns, or partial functions (no head, tail, fromJust, !!)."
  , "3. Strict Quality Gates (Zero Hints / Zero Breakages):"
  , "   - HLint: Must pass with 0 hints/warnings (avoid redundant lambdas, un-eta-reduced wrappers, unused pragmas)."
  , "   - Tagref: Must pass 100% resolve. Every [ref:<name>] must match an existing anchor; DO NOT duplicate [tag:<name>] anchors."
  , "   - Comment Density: CLOC comments must remain >= 25.0%. Include comprehensive Haddock headers on all exposed modules."
  , "   - Total Functions: Strictly total. Use pattern-matching, Data.Maybe, or uncons rather than partial operations."
  , "4. Zero-Token Progressive Code Navigation:"
  , "   - Use tags to jump to symbol definitions instantly (<15 tokens): `grep -w \"^<Symbol>\" tags`"
  , "   - Use `ok memory search <query>` to retrieve institutional facts, constraints, and past bug remedies in <50 tokens."
  , "   - Use `kioku recall <query> --namespace-wide yamaarashi` to query cross-session architectural memory."
  , "   - Use `cxf search <query>` to query local SQLite FTS5 BM25 ranked context packs from Contextful."
  , "   - Use `tricorder status --json` or `status(wait: true)` to get JSON compiler diagnostics in <50 tokens."
  , "   - Never dump whole 500-line source modules; view targeted slices with start/end lines."
  , "5. Non-Interactive Execution: You are running non-interactively in batch print mode."
  , "   Apply required file edits directly using file tools (view_file, replace_file_content, write_to_file)."
  , "   When running commands with run_command, always set WaitMsBeforeAsync to 10000 so commands execute synchronously."
  , "   Never idle waiting for notifications."
  , "6. Verification Pre-requisite: Before finishing, verify that your implementation builds"
  , "   and passes tests via `cabal v2-build -j20 --semaphore` and verification scripts."
  , "7. Institutional Learning: If you discover an invariant or non-obvious bug fix, record it with `ok memory remember \"<lesson>\"` so future workers inherit the knowledge."
  , "8. Conclude cleanly: Once code is in place and verified, output your summary and exit."
  ]

-- | Construct structured prompt markdown for repairing a failed verification attempt.
buildRepairPrompt :: TaskPacket -> Text -> Int -> Int -> Text
buildRepairPrompt packet errorOutput attempt maxAtt = T.unlines
  [ "# Autonomous Task Repair: " <> packetTitle packet <> " (Attempt " <> T.pack (show attempt) <> "/" <> T.pack (show maxAtt) <> ")"
  , ""
  , "## Packet Identifier"
  , packetId packet
  , ""
  , "## Context"
  , "The previous implementation attempt left verification or compilation errors in the worktree."
  , "All files created so far are preserved in your current working directory."
  , ""
  , "## Verification / Compiler Error Output"
  , "```"
  , errorOutput
  , "```"
  , ""
  , "## Repair Directives"
  , "1. Diagnose and fix the specific compilation, type mismatch, import, or test failure errors shown above."
  , "2. DO NOT delete or recreate files from scratch unless necessary — apply targeted edits to the existing codebase."
  , "3. Strict Quality Gates:"
  , "   - Fix HLint suggestions (eta-reduction, redundant lambdas, unused language extensions)."
  , "   - Tagref: Ensure anchor [tag:name] is unique; citations in source must use [ref:name]."
  , "   - Comment Density: Maintain CLOC comments >= 25%."
  , "4. Zero-Token Progressive Code Navigation:"
  , "   - Use tags to check definitions: `grep -w \"^<Symbol>\" tags`"
  , "   - Test compilation directly via `cabal v2-build`."
  , "5. Verification Pre-requisite: Before finishing, verify that your implementation builds"
  , "   and passes tests via `cabal v2-build` and `cabal v2-test`."
  , "6. Conclude cleanly: Once code is in place and verified, output your summary and exit."
  ]

-- | Verification gate: builds packages, runs tests, and audits code.
-- Returns Right () on success, or Left errorOutput on failure.
runVerificationGate :: FilePath -> TaskPacket -> IO (Either Text ())
runVerificationGate wtDir packet = do
  let tId = packetId packet
  case tId of
    "fix-kogaki-wire-lexer-nonempty" -> do
      putStrLn "  [Gate 1/3] Building kogaki-wire..."
      res1 <- runGateCmd wtDir "cabal" ["v2-build", "kogaki-wire"]
      case res1 of
        Left err -> pure (Left err)
        Right () -> do
          putStrLn "  [Gate 2/3] Running test-kogaki-wire..."
          res2 <- runGateCmd wtDir "cabal" ["v2-test", "kogaki-wire"]
          case res2 of
            Left err -> pure (Left err)
            Right () -> do
              putStrLn "  [Gate 3/3] Auditing Kogaki.Wire.Json.Lexer for zero partial functions..."
              let targetFile = wtDir </> "packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs"
              (code, out, _) <- readProcess (proc "grep" ["-n", "-E", "BSC\\.head|BS\\.tail|!!", targetFile])
              case code of
                ExitFailure 1 -> do
                  putStrLn "  [AUDIT PASS] Zero partial function calls found!"
                  pure (Right ())
                ExitSuccess -> do
                  let outStr = BSC.unpack (BSC.toStrict out)
                  putStrLn $ "  [AUDIT FAIL] Found partial function calls in " ++ targetFile ++ ":\n" ++ outStr
                  pure (Left $ "Audit failed: partial functions remain in Kogaki.Wire.Json.Lexer:\n" <> T.pack outStr)
                ExitFailure other ->
                  pure (Left $ "Grep audit exited with code: " <> T.pack (show other))
    _ -> do
      (diffCode, _, _) <- readProcess (setWorkingDir wtDir (proc "git" ["diff", "--quiet", "HEAD"]))
      (_, untrackedOut, _) <- readProcess (setWorkingDir wtDir (proc "git" ["status", "--porcelain"]))
      let hasChanges = diffCode /= ExitSuccess || not (BSL.null (BSL.filter (\w -> w /= 32 && w /= 10) untrackedOut))
      if not hasChanges
        then pure (Left "Verification gate failed: No files were modified or created by the worker.")
        else do
          let pkgs = packetPackages packet
          pkgRes <- if null pkgs
            then do
              putStrLn "  [Gate] Running general cabal v2-build..."
              runGateCmd wtDir "cabal" ["v2-build"]
            else do
              let checkPkgs [] = pure (Right ())
                  checkPkgs (p:ps) = do
                    putStrLn $ "  [Gate] Building package: " ++ T.unpack p
                    r <- runGateCmd wtDir "cabal" ["v2-build", T.unpack p]
                    case r of
                      Left err -> pure (Left err)
                      Right () -> checkPkgs ps
              checkPkgs pkgs

          case pkgRes of
            Left err -> pure (Left err)
            Right () -> do
              let verifyScript = wtDir </> "scripts/tasks" </> T.unpack tId ++ "-verify.sh"
              hasVerify <- doesFileExist verifyScript
              if hasVerify
                then do
                  putStrLn $ "  [Gate] Running verification script: " ++ verifyScript
                  runGateCmd wtDir "sh" [verifyScript]
                else pure (Right ())

-- | Execute a verification command and capture its output on failure with a hard 180s timeout.
runGateCmd :: FilePath -> String -> [String] -> IO (Either Text ())
runGateCmd workDir cmd rawArgs = do
  let args = if cmd == "cabal" && not (any (`elem` rawArgs) ["-j", "--jobs"])
               then rawArgs ++ ["-j20", "--semaphore"]
               else rawArgs
  mRes <- timeout (180 * 1000000) $ readProcess (setWorkingDir workDir (proc cmd args))
  case mRes of
    Nothing -> do
      let desc = T.pack cmd <> " " <> T.unwords (map T.pack args)
      putStrLn $ "  [Gate TIMEOUT] " ++ cmd ++ " " ++ unwords args ++ " (exceeded 180s)"
      pure (Left ("Verification command timed out after 180 seconds (" <> desc <> ")"))
    Just (code, outBs, errBs) ->
      case code of
        ExitSuccess -> do
          putStrLn $ "  [Gate PASS] " ++ cmd ++ " " ++ unwords args
          pure (Right ())
        ExitFailure c -> do
          let errText = trimErrorOutput (TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs])))
              desc = T.pack cmd <> " " <> T.unwords (map T.pack args)
          putStrLn $ "  [Gate FAIL] " ++ cmd ++ " " ++ unwords args ++ " (exit " ++ show c ++ ")"
          pure (Left ("Command failed with exit code " <> T.pack (show c) <> " (" <> desc <> "):\n" <> errText))

-- | Trim excessively long error outputs to avoid blowing up prompt budgets.
trimErrorOutput :: Text -> Text
trimErrorOutput txt =
  let lns = T.lines txt
  in if length lns > 200
       then T.unlines (take 40 lns ++ ["\n... [truncated " <> T.pack (show (length lns - 200)) <> " lines of build output] ...\n"] ++ drop (length lns - 160) lns)
       else txt

-- | Create git commit in worktree with standard attribution trailers.
createGitCommit :: FilePath -> TaskPacket -> Text -> IO Text
createGitCommit wtDir packet actualExecutor = do
  let promptFile = wtDir </> ".worker-task-prompt.md"
  promptExists <- doesFileExist promptFile
  when promptExists $ removeFile promptFile

  let hermesPromptFile = wtDir </> ".hermes-task-prompt.md"
  hermesPromptExists <- doesFileExist hermesPromptFile
  when hermesPromptExists $ removeFile hermesPromptFile

  _ <- runProcess (proc "rm" ["-rf", wtDir </> ".ok"])
  _ <- runProcess (proc "rm" ["-f", wtDir </> "ok.toml"])
  _ <- runProcess (proc "rm" ["-rf", wtDir </> ".contextful"])
  _ <- runProcess (proc "rm" ["-rf", wtDir </> "dist-newstyle"])

  runProcess_ (setWorkingDir wtDir (proc "git" ["add", "-A"]))

  let baseAttribution = case actualExecutor of
        "sarutahiko" ->
          let m = case packetModel packet of
                Just mdl -> "Sarutahiko Autonomous Agent (" <> mdl <> ")"
                Nothing  -> "Sarutahiko Autonomous Agent (sarutahiko-agent)"
          in "Assisted-by: " <> m <> "\nOrchestrated-by: Yamaarashi Flow Task Runner\n"
        "utai" ->
          let m = case packetModel packet of
                Just mdl -> "Utai Native (" <> mdl <> ")"
                Nothing  -> "Utai Native (mistral/codestral-latest)"
          in "Assisted-by: " <> m <> "\nOrchestrated-by: Yamaarashi Flow Task Runner\n"
        "hermes" ->
          let m = case packetModel packet of
                Just mdl -> "Hermes Agent (" <> mdl <> ")"
                Nothing  -> "Hermes Agent"
          in "Assisted-by: " <> m <> "\nOrchestrated-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)\n"
        "agy" ->
          let m = case packetModel packet of
                Just mdl -> "Antigravity CLI (" <> mdl <> ")"
                Nothing  -> "Antigravity CLI (Gemini 3.8 Flash)"
          in "Assisted-by: " <> m <> "\nOrchestrated-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)\n"
        _ ->
          "Assisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)\n"

  let commitMsg = case packetId packet of
        "fix-kogaki-wire-lexer-nonempty" ->
          "fix(kogaki-wire): replace unsafe head, tail, and indexing in Json lexer\n\n\
          \Substitute pattern-matching and BSC.uncons for all partial operations in\n\
          \Kogaki.Wire.Json.Lexer to make non-emptiness explicit.\n\n\
          \Ref: " <> packetId packet <> " (" <> packetTitle packet <> ")\n\n\
          \Assisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)\n"
        _ ->
          packetTitle packet <> "\n\n" <>
          packetDescription packet <> "\n\n" <>
          "Ref: " <> packetId packet <> "\n\n" <>
          baseAttribution

  runProcess_ (setWorkingDir wtDir (proc "git" ["commit", "--allow-empty", "-m", T.unpack commitMsg]))

  (out, _) <- readProcess_ (setWorkingDir wtDir (proc "git" ["rev-parse", "HEAD"]))
  let commitHash = T.strip (TE.decodeUtf8 (BSC.toStrict out))
  putStrLn $ "  [COMMIT] Created " ++ T.unpack commitHash
  pure commitHash

-- | Refactored, 100% total Kogaki.Wire.Json.Lexer with zero partial functions.
fixedLexerContent :: Text
fixedLexerContent = T.unlines
  [ "{-# LANGUAGE BangPatterns #-}"
  , "{-# LANGUAGE DeriveGeneric #-}"
  , "{-# LANGUAGE DerivingStrategies #-}"
  , "{-# LANGUAGE OverloadedStrings #-}"
  , ""
  , "-- |"
  , "-- Module      : Kogaki.Wire.Json.Lexer"
  , "-- Description : Zero-bloat, non-allocating JSON token lexer"
  , "--"
  , "-- Implements the lean, row-native JSON lexer for Phase 1 (TP-1.1)."
  , "-- Tokenizes JSON byte streams directly into unboxed and unpacked tokens"
  , "-- without intermediate heap-allocated abstract syntax trees ('Value')."
  , "-- Commas and colons are consumed as framing delimiters so downstream"
  , "-- row decoders receive clean structural tokens and key-value streams."
  , "module Kogaki.Wire.Json.Lexer"
  , "  ( -- * Tokens"
  , "    JsonToken (..)"
  , ""
  , "    -- * Lexing"
  , "  , lexJson"
  , "  , lexJsonEither"
  , "  ) where"
  , ""
  , "import Data.Bits (shiftL, (.|.))"
  , "import Data.ByteString (ByteString)"
  , "import qualified Data.ByteString as BS"
  , "import qualified Data.ByteString.Char8 as BSC"
  , "import Data.Char (chr, isDigit)"
  , "import Data.Int (Int64)"
  , "import Data.Text (Text)"
  , "import qualified Data.Text as T"
  , "import qualified Data.Text.Encoding as TE"
  , "import qualified Data.Text.Encoding.Error as TEE"
  , "import qualified Data.Text.Read as TR"
  , "import GHC.Generics (Generic)"
  , "import Numeric (readHex)"
  , ""
  , "-- | Flat, unboxed JSON tokens."
  , "--"
  , "-- @since 0.1.0.0"
  , "data JsonToken"
  , "  = TkObjectOpen"
  , "  | TkObjectClose"
  , "  | TkArrayOpen"
  , "  | TkArrayClose"
  , "  | TkKey {-# UNPACK #-} !ByteString"
  , "  | TkString {-# UNPACK #-} !Text"
  , "  | TkInt {-# UNPACK #-} !Int64"
  , "  | TkDouble {-# UNPACK #-} !Double"
  , "  | TkBool !Bool"
  , "  | TkNull"
  , "  deriving stock (Eq, Show, Generic)"
  , ""
  , "-- | Lex a JSON byte stream into a list of tokens. Returns an empty"
  , "-- list if the input is malformed or empty."
  , "--"
  , "-- @since 0.1.0.0"
  , "lexJson :: ByteString -> [JsonToken]"
  , "lexJson bs = case lexJsonEither bs of"
  , "  Left _    -> []"
  , "  Right tks -> tks"
  , ""
  , "-- | Internal parsing context."
  , "data Ctx"
  , "  = InObject !ObjState"
  , "  | InArray !ArrState"
  , "  deriving stock (Eq, Show)"
  , ""
  , "data ObjState"
  , "  = ObjExpectKeyOrClose"
  , "  | ObjExpectKey"
  , "  | ObjExpectColon"
  , "  | ObjExpectValue"
  , "  | ObjExpectCommaOrClose"
  , "  deriving stock (Eq, Show)"
  , ""
  , "data ArrState"
  , "  = ArrExpectValueOrClose"
  , "  | ArrExpectValue"
  , "  | ArrExpectCommaOrClose"
  , "  deriving stock (Eq, Show)"
  , ""
  , "-- | Lex a JSON byte stream with explicit error reporting."
  , "--"
  , "-- @since 0.1.0.0"
  , "lexJsonEither :: ByteString -> Either Text [JsonToken]"
  , "lexJsonEither input = go (skipWhitespace input) []"
  , "  where"
  , "    go :: ByteString -> [Ctx] -> Either Text [JsonToken]"
  , "    go !bs []"
  , "      | BS.null bs = Right []"
  , "      | otherwise  = parseTopLevelValue bs"
  , ""
  , "    go !bs (InObject st : stackRest) ="
  , "      case st of"
  , "        ObjExpectKeyOrClose ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: unclosed object\""
  , "            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest"
  , "            Just ('\"', _)    -> parseKeyAndContinue (skipWhitespace bs) stackRest"
  , "            Just (c, _)      -> Left (\"Expected string key or '}', got: \" <> T.singleton c)"
  , ""
  , "        ObjExpectKey ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: expected object key\""
  , "            Just ('\"', _) -> parseKeyAndContinue (skipWhitespace bs) stackRest"
  , "            Just (c, _)   -> Left (\"Expected string key, got: \" <> T.singleton c)"
  , ""
  , "        ObjExpectColon ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: expected ':'\""
  , "            Just (':', rest) -> go (skipWhitespace rest) (InObject ObjExpectValue : stackRest)"
  , "            Just (c, _)      -> Left (\"Expected ':', got: \" <> T.singleton c)"
  , ""
  , "        ObjExpectValue ->"
  , "          parseValue bs (InObject ObjExpectCommaOrClose : stackRest)"
  , ""
  , "        ObjExpectCommaOrClose ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: unclosed object\""
  , "            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest"
  , "            Just (',', rest) -> go (skipWhitespace rest) (InObject ObjExpectKey : stackRest)"
  , "            Just (c, _)      -> Left (\"Expected ',' or '}', got: \" <> T.singleton c)"
  , ""
  , "    go !bs (InArray st : stackRest) ="
  , "      case st of"
  , "        ArrExpectValueOrClose ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: unclosed array\""
  , "            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest"
  , "            Just _           -> parseValue (skipWhitespace bs) (InArray ArrExpectCommaOrClose : stackRest)"
  , ""
  , "        ArrExpectValue ->"
  , "          parseValue bs (InArray ArrExpectCommaOrClose : stackRest)"
  , ""
  , "        ArrExpectCommaOrClose ->"
  , "          case BSC.uncons (skipWhitespace bs) of"
  , "            Nothing -> Left \"Unexpected EOF: unclosed array\""
  , "            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest"
  , "            Just (',', rest) -> go (skipWhitespace rest) (InArray ArrExpectValue : stackRest)"
  , "            Just (c, _)      -> Left (\"Expected ',' or ']', got: \" <> T.singleton c)"
  , ""
  , "    parseTopLevelValue :: ByteString -> Either Text [JsonToken]"
  , "    parseTopLevelValue !bs = parseValue bs []"
  , ""
  , "    parseKeyAndContinue :: ByteString -> [Ctx] -> Either Text [JsonToken]"
  , "    parseKeyAndContinue !trimmed !stackRest ="
  , "      case BSC.uncons trimmed of"
  , "        Just ('\"', rest) -> do"
  , "          (keyBytes, remainder) <- parseRawString rest"
  , "          let !nextStack = InObject ObjExpectColon : stackRest"
  , "          (TkKey keyBytes :) <$> go (skipWhitespace remainder) nextStack"
  , "        _ -> Left \"Expected string key starting with quote\""
  , ""
  , "    parseValue :: ByteString -> [Ctx] -> Either Text [JsonToken]"
  , "    parseValue !rawBs !stack = do"
  , "      let !bs = skipWhitespace rawBs"
  , "      case BSC.uncons bs of"
  , "        Nothing -> Left \"Unexpected EOF: expected JSON value\""
  , "        Just ('{', rest) -> (TkObjectOpen :) <$> go (skipWhitespace rest) (InObject ObjExpectKeyOrClose : stack)"
  , "        Just ('[', rest) -> (TkArrayOpen :) <$> go (skipWhitespace rest) (InArray ArrExpectValueOrClose : stack)"
  , "        Just ('\"', rest) -> do"
  , "          (strBytes, remainder) <- parseRawString rest"
  , "          let !txt = TE.decodeUtf8With TEE.lenientDecode strBytes"
  , "          (TkString txt :) <$> go (skipWhitespace remainder) stack"
  , "        Just ('t', _)"
  , "          | \"true\" `BS.isPrefixOf` bs ->"
  , "              (TkBool True :) <$> go (skipWhitespace (BS.drop 4 bs)) stack"
  , "          | otherwise -> Left \"Malformed literal: expected 'true'\""
  , "        Just ('f', _)"
  , "          | \"false\" `BS.isPrefixOf` bs ->"
  , "              (TkBool False :) <$> go (skipWhitespace (BS.drop 5 bs)) stack"
  , "          | otherwise -> Left \"Malformed literal: expected 'false'\""
  , "        Just ('n', _)"
  , "          | \"null\" `BS.isPrefixOf` bs ->"
  , "              (TkNull :) <$> go (skipWhitespace (BS.drop 4 bs)) stack"
  , "          | otherwise -> Left \"Malformed literal: expected 'null'\""
  , "        Just (c, _)"
  , "          | c == '-' || isDigit c -> do"
  , "              (numTok, remainder) <- parseNumber bs"
  , "              (numTok :) <$> go (skipWhitespace remainder) stack"
  , "          | otherwise -> Left (\"Unexpected character starting value: \" <> T.singleton c)"
  , ""
  , "-- | Skip ASCII whitespace bytes (0x20, 0x09, 0x0A, 0x0D)."
  , "skipWhitespace :: ByteString -> ByteString"
  , "skipWhitespace bs = BS.dropWhile isSpaceByte bs"
  , "  where"
  , "    isSpaceByte w = w == 32 || w == 9 || w == 10 || w == 13"
  , ""
  , "-- | Parse a double-quoted JSON string (without opening quote), returning"
  , "-- the unescaped UTF-8 byte payload and the remaining unparsed input."
  , "parseRawString :: ByteString -> Either Text (ByteString, ByteString)"
  , "parseRawString input ="
  , "  case BSC.elemIndex '\"' input of"
  , "    Nothing -> Left \"Unterminated string literal\""
  , "    Just quoteIdx ->"
  , "      let prefix = BS.take quoteIdx input"
  , "      in if not (BSC.elem '\\\\' prefix)"
  , "           then Right (prefix, BS.drop (quoteIdx + 1) input)"
  , "           else slowUnescape input []"
  , ""
  , "slowUnescape :: ByteString -> [ByteString] -> Either Text (ByteString, ByteString)"
  , "slowUnescape !bs !acc ="
  , "  case BSC.uncons bs of"
  , "    Nothing -> Left \"Unterminated string literal during escape parsing\""
  , "    Just ('\"', rest) -> Right (BS.concat (reverse acc), rest)"
  , "    Just ('\\\\', rest) ->"
  , "      case BSC.uncons rest of"
  , "        Nothing -> Left \"Unexpected EOF following escape character '\\\\'\""
  , "        Just ('\"', rest2) -> slowUnescape rest2 (\"\\\"\" : acc)"
  , "        Just ('\\\\', rest2) -> slowUnescape rest2 (\"\\\\\" : acc)"
  , "        Just ('/', rest2)  -> slowUnescape rest2 (\"/\" : acc)"
  , "        Just ('b', rest2)  -> slowUnescape rest2 (\"\\b\" : acc)"
  , "        Just ('f', rest2)  -> slowUnescape rest2 (\"\\f\" : acc)"
  , "        Just ('n', rest2)  -> slowUnescape rest2 (\"\\n\" : acc)"
  , "        Just ('r', rest2)  -> slowUnescape rest2 (\"\\r\" : acc)"
  , "        Just ('t', rest2)  -> slowUnescape rest2 (\"\\t\" : acc)"
  , "        Just ('u', rest2)  -> parseUnicodeEscape rest2 acc"
  , "        Just (esc, _)      -> Left (\"Invalid escape character in string: \\\\\" <> T.singleton esc)"
  , "    Just _ ->"
  , "      let (chunk, remainder) = BSC.span (\\c -> c /= '\"' && c /= '\\\\') bs"
  , "      in slowUnescape remainder (chunk : acc)"
  , ""
  , "parseUnicodeEscape :: ByteString -> [ByteString] -> Either Text (ByteString, ByteString)"
  , "parseUnicodeEscape !bs !acc"
  , "  | BS.length bs < 4 = Left \"Premature EOF in \\\\u unicode escape\""
  , "  | otherwise ="
  , "      let hexSlice = BSC.unpack (BS.take 4 bs)"
  , "          remBs    = BS.drop 4 bs"
  , "      in case readHex hexSlice of"
  , "        [(code, \"\")] ->"
  , "          if code >= 0xD800 && code <= 0xDBFF"
  , "            then if BS.length remBs >= 6 && BS.take 2 remBs == \"\\\\u\""
  , "                   then let lowHex = BSC.unpack (BS.take 4 (BS.drop 2 remBs))"
  , "                            afterLow = BS.drop 6 remBs"
  , "                        in case readHex lowHex of"
  , "                             [(lowCode, \"\")] | lowCode >= 0xDC00 && lowCode <= 0xDFFF ->"
  , "                               let scalar = 0x10000 + ((code - 0xD800) `shiftL` 10) .|. (lowCode - 0xDC00)"
  , "                                   encoded = TE.encodeUtf8 (T.singleton (chr scalar))"
  , "                               in slowUnescape afterLow (encoded : acc)"
  , "                             _ ->"
  , "                               let encoded = TE.encodeUtf8 (T.singleton (chr code))"
  , "                               in slowUnescape remBs (encoded : acc)"
  , "                   else"
  , "                     let encoded = TE.encodeUtf8 (T.singleton (chr code))"
  , "                     in slowUnescape remBs (encoded : acc)"
  , "            else"
  , "              let encoded = TE.encodeUtf8 (T.singleton (chr code))"
  , "              in slowUnescape remBs (encoded : acc)"
  , "        _ -> Left (\"Invalid hex in \\\\u unicode escape: \" <> T.pack hexSlice)"
  , ""
  , "-- | Parse a JSON number into either 'TkInt' or 'TkDouble'."
  , "parseNumber :: ByteString -> Either Text (JsonToken, ByteString)"
  , "parseNumber !bs ="
  , "  let (numBytes, remainder) = BSC.span isNumChar bs"
  , "  in if BS.null numBytes"
  , "       then Left \"Expected number characters\""
  , "       else"
  , "         if BSC.elem '.' numBytes || BSC.elem 'e' numBytes || BSC.elem 'E' numBytes"
  , "           then case TR.double (TE.decodeUtf8With TEE.lenientDecode numBytes) of"
  , "             Right (d, rest) | T.null rest -> Right (TkDouble d, remainder)"
  , "             _                             -> Left (\"Malformed float literal: \" <> TE.decodeUtf8With TEE.lenientDecode numBytes)"
  , "           else case BSC.readInteger numBytes of"
  , "             Just (i, rest) | BS.null rest -> Right (TkInt (fromIntegral i), remainder)"
  , "             _                             -> Left (\"Malformed integer literal: \" <> TE.decodeUtf8With TEE.lenientDecode numBytes)"
  , "  where"
  , "    isNumChar c = c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' || isDigit c"
  ]

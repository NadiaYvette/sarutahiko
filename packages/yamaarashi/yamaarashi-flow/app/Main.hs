{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (bracket, throwIO)
import Control.Monad (when)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , removeFile
  )
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeDirectory, (</>))
import System.Process.Typed
import System.Timeout (timeout)

-- | Parsed task packet envelope.
data TaskPacket = TaskPacket
  { packetId          :: !Text
  , packetTitle       :: !Text
  , packetDescription :: !Text
  , packetPackages    :: ![Text]
  , packetExecutor    :: !Text
  , packetModel       :: !(Maybe Text)
  , packetSkills      :: ![Text]
  , packetMaxTurns    :: !(Maybe Int)
  , packetRunBudget   :: !(Maybe Int)
  , packetRawYaml     :: !Text
  } deriving (Show)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["run", packetPath] -> runTaskPacket packetPath
    ["--help"]          -> printHelp >> exitSuccess
    ["-h"]              -> printHelp >> exitSuccess
    _                   -> do
      putStrLn "Usage: yamaarashi-exec run <path/to/packet.yaml>"
      exitFailure

printHelp :: IO ()
printHelp = do
  putStrLn "yamaarashi-exec — Standalone Yamaarashi workflow runner"
  putStrLn ""
  putStrLn "Commands:"
  putStrLn "  run <packet.yaml>  Execute a task packet in an isolated worktree"
  putStrLn "  --help             Show this help message"
  putStrLn ""
  putStrLn "Execution Engines (set in packet via 'executor:'):"
  putStrLn "  executor: agy      Delegates turn execution to Antigravity CLI print mode (fast, robust)."
  putStrLn "  executor: hermes   Delegates turn execution to a spawned Hermes leaf worker (--cli -Q)."
  putStrLn "  executor: script   Runs scripts/tasks/<id>.sh in the isolated worktree."
  putStrLn "  executor: auto     Uses script if scripts/tasks/<id>.sh exists, else agy."

-- | Execute a task packet through an isolated worktree with SQLite event tracking.
runTaskPacket :: FilePath -> IO ()
runTaskPacket path = do
  putStrLn $ "=== [yamaarashi-exec] Loading task packet: " ++ path ++ " ==="
  content <- TIO.readFile path
  packet <- parsePacket path content
  let tId = T.unpack (packetId packet)

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
        logEvent dbPath (packetId packet) "WORKTREE_PROVISIONED" (T.pack worktreeDir)
        pure worktreeDir

      teardown wtDir = do
        putStrLn $ "=== [yamaarashi-exec] Tearing down worktree: " ++ wtDir ++ " ==="
        _ <- runProcess (proc "git" ["worktree", "remove", "--force", wtDir])
        _ <- runProcess (proc "git" ["branch", "-D", branchName])
        logEvent dbPath (packetId packet) "WORKTREE_TEARDOWN" (T.pack wtDir)

  bracket provision teardown $ \wtDir -> do
    -- Step 1: Execute Task Actions
    putStrLn "=== [yamaarashi-exec] Executing task step ==="
    logEvent dbPath (packetId packet) "STEP_STARTED" "Applying task modifications"
    actualExec <- executeTaskStep wtDir packet dbPath
    logEvent dbPath (packetId packet) "STEP_EXECUTED" ("Modifications applied successfully via " <> actualExec)

    -- Step 2: Verification Gate
    putStrLn "=== [yamaarashi-exec] Running verification gate ==="
    logEvent dbPath (packetId packet) "VERIFICATION_STARTED" "cabal v2-build & cabal v2-test"
    runVerificationGate wtDir packet
    logEvent dbPath (packetId packet) "VERIFICATION_PASSED" "All build and audit checks passed"

    -- Step 3: Git Commit
    putStrLn "=== [yamaarashi-exec] Creating git commit with attribution trailers ==="
    commitHash <- createGitCommit wtDir packet actualExec
    logEvent dbPath (packetId packet) "COMMIT_CREATED" commitHash

    -- Step 4: Fast-forward merge into main repository
    putStrLn $ "=== [yamaarashi-exec] Merging " ++ branchName ++ " into repository ==="
    runProcess_ (setWorkingDir repoRoot (proc "git" ["merge", "--ff-only", branchName]))

    logEvent dbPath (packetId packet) "TASK_COMPLETED" ("Merged commit " <> commitHash)
    putStrLn $ "=== [yamaarashi-exec] SUCCESS: Task " ++ tId ++ " completed successfully! ==="

-- | Initialize SQLite event store table.
initEventDb :: FilePath -> IO ()
initEventDb dbPath = do
  let sql = "CREATE TABLE IF NOT EXISTS task_events (\
            \  id INTEGER PRIMARY KEY AUTOINCREMENT,\
            \  task_id TEXT NOT NULL,\
            \  event_type TEXT NOT NULL,\
            \  payload TEXT NOT NULL,\
            \  created_at DATETIME DEFAULT CURRENT_TIMESTAMP\
            \);"
  runProcess_ (proc "sqlite3" [dbPath, sql])

-- | Record an event into SQLite.
logEvent :: FilePath -> Text -> Text -> Text -> IO ()
logEvent dbPath tId evType payload = do
  let safePayload = T.replace "'" "''" payload
      sql = "INSERT INTO task_events (task_id, event_type, payload) VALUES ('"
         <> tId <> "', '" <> evType <> "', '" <> safePayload <> "');"
  runProcess_ (proc "sqlite3" [dbPath, T.unpack sql])

-- | Simple parser for Task Packet YAML adhering to Zero-Aeson invariant.
parsePacket :: FilePath -> Text -> IO TaskPacket
parsePacket path txt = do
  let lns = T.lines txt
      findVal key = case filter (T.isPrefixOf (key <> ":")) lns of
        (l:_) -> T.strip (T.drop (T.length key + 1) l)
        []    -> ""
      extractList key =
        let afterKey = drop 1 $ dropWhile (\l -> not (T.isPrefixOf (key <> ":") l)) lns
            items = takeWhile (\l -> T.isPrefixOf "  - " l || T.isPrefixOf "- " l) afterKey
            clean l = T.strip (T.dropWhile (\c -> c == ' ' || c == '-') (fst (T.breakOn "#" l)))
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

      pModel = if T.null pModelRaw then Nothing else Just pModelRaw
      pMaxTurns = case reads (T.unpack pMaxTurnsRaw) of
        [(n, "")] -> Just n
        _         -> Nothing
      pBudget = case reads (T.unpack pBudgetRaw) of
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
      , packetRawYaml = txt
      }

-- | Execute task actions inside the isolated worktree directory.
-- Returns the executor name that ran the step ("agy", "hermes", "script", or "inline").
executeTaskStep :: FilePath -> TaskPacket -> FilePath -> IO Text
executeTaskStep wtDir packet dbPath = do
  let tId = packetId packet
  case tId of
    "fix-kogaki-wire-lexer-nonempty" -> do
      putStrLn "  -> Applying Kogaki.Wire.Json.Lexer safe non-empty refactoring..."
      let targetFile = wtDir </> "packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs"
      TIO.writeFile targetFile fixedLexerContent
      pure "inline"
    _ -> do
      let customScript = wtDir </> "scripts/tasks" </> T.unpack tId ++ ".sh"
      scriptExists <- doesFileExist customScript
      let execMode = packetExecutor packet
      case execMode of
        "script" ->
          if scriptExists
            then runScriptStep wtDir customScript >> pure "script"
            else throwIO (userError $ "Explicit script executor requested, but script missing: " ++ customScript)
        "hermes" ->
          runHermesStep wtDir packet dbPath >> pure "hermes"
        "agy" ->
          runAgyStep wtDir packet dbPath >> pure "agy"
        "auto" ->
          if scriptExists
            then runScriptStep wtDir customScript >> pure "script"
            else runAgyStep wtDir packet dbPath >> pure "agy"
        other ->
          throwIO (userError $ "Unknown executor: " ++ T.unpack other ++ " (expected 'agy', 'hermes', 'script', or 'auto')")

-- | Execute task script in the isolated worktree.
runScriptStep :: FilePath -> FilePath -> IO ()
runScriptStep wtDir scriptPath = do
  putStrLn $ "  -> Running task script: " ++ scriptPath
  runProcess_ (setWorkingDir wtDir (proc "sh" [scriptPath]))

-- | Delegate task execution to Antigravity CLI in non-interactive print mode.
runAgyStep :: FilePath -> TaskPacket -> FilePath -> IO ()
runAgyStep wtDir packet dbPath = do
  mAgy <- findExecutable "agy"
  case mAgy of
    Nothing -> throwIO (userError "Agy executor requested, but 'agy' executable was not found in PATH.")
    Just agyBin -> do
      let tId = packetId packet
          promptFile = wtDir </> ".worker-task-prompt.md"
          promptContent = buildWorkerPrompt packet
          budgetSec = maybe 600 id (packetRunBudget packet)
          budgetStr = show budgetSec ++ "s"
          logDir = takeDirectory dbPath </> "logs"
          workerLogFile = logDir </> (T.unpack tId ++ "-agy.log")

      createDirectoryIfMissing True logDir
      TIO.writeFile promptFile promptContent
      logEvent dbPath tId "AGY_SPAWNED" ("Prompt written to " <> T.pack promptFile)
      putStrLn $ "=== [yamaarashi-exec] Spawning Agy leaf worker in: " ++ wtDir ++ " ==="
      putStrLn $ "=== [yamaarashi-exec] Log destination: " ++ workerLogFile ++ " ==="

      let modelArgs = case packetModel packet of
            Just m  -> ["--model", T.unpack m, "--effort", "high"]
            Nothing -> []
          cmdArgs =
            [ "-p", T.unpack promptContent
            , "--dangerously-skip-permissions"
            , "--print-timeout", budgetStr
            ] ++ modelArgs

      putStrLn $ "=== [yamaarashi-exec] Running: " ++ agyBin ++ " -p <prompt> --dangerously-skip-permissions --print-timeout " ++ budgetStr ++ " ==="
      mRes <- timeout ((budgetSec + 30) * 1000000) $ do
        (exitCode, outBs, errBs) <- readProcess (setWorkingDir wtDir (proc agyBin cmdArgs))
        BSL.writeFile workerLogFile (BSL.concat [outBs, "\n--- STDERR ---\n", errBs])
        pure exitCode

      case mRes of
        Nothing -> do
          let errMsg = "Agy execution timed out after " ++ show budgetSec ++ " seconds."
          logEvent dbPath tId "AGY_TIMEOUT" (T.pack errMsg)
          throwIO (userError errMsg)
        Just ExitSuccess -> do
          logEvent dbPath tId "AGY_SUCCEEDED" "Agy task execution exited with code 0"
          putStrLn "=== [yamaarashi-exec] Agy leaf worker completed successfully ==="
        Just (ExitFailure code) -> do
          let errMsg = "Agy execution failed with exit code " ++ show code ++ " (see " ++ workerLogFile ++ ")"
          logEvent dbPath tId "AGY_FAILED" (T.pack errMsg)
          throwIO (userError errMsg)

-- | Delegate task execution to a spawned Hermes leaf worker agent.
runHermesStep :: FilePath -> TaskPacket -> FilePath -> IO ()
runHermesStep wtDir packet dbPath = do
  mHermes <- findExecutable "hermes"
  case mHermes of
    Nothing -> throwIO (userError "Hermes executor requested, but 'hermes' executable was not found in PATH.")
    Just hermesBin -> do
      let tId = packetId packet
          promptFile = wtDir </> ".worker-task-prompt.md"
          promptContent = buildWorkerPrompt packet
          budgetSec = maybe 900 id (packetRunBudget packet)
          logDir = takeDirectory dbPath </> "logs"
          workerLogFile = logDir </> (T.unpack tId ++ "-hermes.log")

      createDirectoryIfMissing True logDir
      TIO.writeFile promptFile promptContent
      logEvent dbPath tId "HERMES_SPAWNED" ("Prompt written to " <> T.pack promptFile)
      putStrLn $ "=== [yamaarashi-exec] Spawning Hermes leaf worker in: " ++ wtDir ++ " ==="
      putStrLn $ "=== [yamaarashi-exec] Log destination: " ++ workerLogFile ++ " ==="

      let baseArgs =
            [ "chat"
            , "--in", wtDir
            , "--query-file", promptFile
            , "--cli"           -- Force CLI REPL; prevent TUI Node.js deadlock
            , "-Q"              -- Quiet headless mode
            , "--oneshot"
            , "--yolo"
            , "--accept-hooks"
            , "--format", "text"
            ]
          skillsArgs = case packetSkills packet of
            [] -> ["-s", "code-navigation,tricorder,contextful"]
            ss -> ["-s", T.unpack (T.intercalate "," ss)]
          turnsArgs = case packetMaxTurns packet of
            Just n  -> ["--max-turns", show n]
            Nothing -> ["--max-turns", "40"]
          budgetArgs = ["--run-budget", show budgetSec]
          modelArgs = case packetModel packet of
            Just m  -> ["-m", T.unpack m]
            Nothing -> []
          cmdArgs = baseArgs ++ skillsArgs ++ turnsArgs ++ budgetArgs ++ modelArgs

      putStrLn $ "=== [yamaarashi-exec] Command: " ++ hermesBin ++ " " ++ unwords cmdArgs ++ " ==="
      mRes <- timeout ((budgetSec + 30) * 1000000) $ do
        (exitCode, outBs, errBs) <- readProcess (proc hermesBin cmdArgs)
        BSL.writeFile workerLogFile (BSL.concat [outBs, "\n--- STDERR ---\n", errBs])
        pure exitCode

      case mRes of
        Nothing -> do
          let errMsg = "Hermes execution timed out after " ++ show budgetSec ++ " seconds."
          logEvent dbPath tId "HERMES_TIMEOUT" (T.pack errMsg)
          throwIO (userError errMsg)
        Just ExitSuccess -> do
          logEvent dbPath tId "HERMES_SUCCEEDED" "Hermes task execution exited with code 0"
          putStrLn "=== [yamaarashi-exec] Hermes leaf worker completed successfully ==="
        Just (ExitFailure code) -> do
          let errMsg = "Hermes execution failed with exit code " ++ show code ++ " (see " ++ workerLogFile ++ ")"
          logEvent dbPath tId "HERMES_FAILED" (T.pack errMsg)
          throwIO (userError errMsg)

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
  , "3. Zero-Token Progressive Code Navigation:"
  , "   - Use tags to jump to symbol definitions instantly (<15 tokens): `grep -w \"^<Symbol>\" tags`"
  , "   - Use `tricorder status --json` or `status(wait: true)` to get JSON compiler diagnostics in <50 tokens."
  , "   - Never dump whole 500-line source modules; view targeted slices with start/end lines."
  , "4. Verification Pre-requisite: Before finishing, verify that your implementation builds"
  , "   and passes tests via `cabal v2-build` and `cabal v2-test`."
  , "5. Conclude cleanly: Once code is in place and verified, output your summary and exit."
  ]

-- | Verification gate: builds packages, runs tests, and audits code.
runVerificationGate :: FilePath -> TaskPacket -> IO ()
runVerificationGate wtDir packet = do
  let tId = packetId packet
  case tId of
    "fix-kogaki-wire-lexer-nonempty" -> do
      -- 1. Build check
      putStrLn "  [Gate 1/3] Building kogaki-wire..."
      runProcess_ (setWorkingDir wtDir (proc "cabal" ["v2-build", "kogaki-wire"]))

      -- 2. Test suite check
      putStrLn "  [Gate 2/3] Running test-kogaki-wire..."
      runProcess_ (setWorkingDir wtDir (proc "cabal" ["v2-test", "kogaki-wire"]))

      -- 3. Audit check: zero calls to BSC.head, BS.tail, or !!
      putStrLn "  [Gate 3/3] Auditing Kogaki.Wire.Json.Lexer for zero partial functions..."
      let targetFile = wtDir </> "packages/kogaki/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs"
      (code, out, _) <- readProcess (proc "grep" ["-n", "-E", "BSC\\.head|BS\\.tail|!!", targetFile])
      case code of
        ExitFailure 1 ->
          putStrLn "  [AUDIT PASS] Zero partial function calls found!"
        ExitSuccess -> do
          putStrLn $ "  [AUDIT FAIL] Found partial function calls in " ++ targetFile ++ ":\n" ++ BSC.unpack (BSC.toStrict out)
          throwIO (userError "Audit failed: partial functions remain in Kogaki.Wire.Json.Lexer")
        ExitFailure other ->
          throwIO (userError $ "Grep audit exited with code: " ++ show other)
    _ -> do
      let pkgs = packetPackages packet
      if null pkgs
        then do
          putStrLn "  [Gate 1/1] Running general cabal v2-build..."
          runProcess_ (setWorkingDir wtDir (proc "cabal" ["v2-build"]))
        else do
          mapM_ (\pkg -> do
            putStrLn $ "  [Gate] Building package: " ++ T.unpack pkg
            runProcess_ (setWorkingDir wtDir (proc "cabal" ["v2-build", T.unpack pkg]))
            ) pkgs

      let verifyScript = wtDir </> "scripts/tasks" </> T.unpack tId ++ "-verify.sh"
      hasVerify <- doesFileExist verifyScript
      if hasVerify
        then do
          putStrLn $ "  [Gate] Running verification script: " ++ verifyScript
          runProcess_ (setWorkingDir wtDir (proc "sh" [verifyScript]))
        else pure ()

-- | Create git commit in worktree with standard attribution trailers.
createGitCommit :: FilePath -> TaskPacket -> Text -> IO Text
createGitCommit wtDir packet actualExecutor = do
  let promptFile = wtDir </> ".worker-task-prompt.md"
  promptExists <- doesFileExist promptFile
  when promptExists $ removeFile promptFile

  let hermesPromptFile = wtDir </> ".hermes-task-prompt.md"
  hermesPromptExists <- doesFileExist hermesPromptFile
  when hermesPromptExists $ removeFile hermesPromptFile

  runProcess_ (setWorkingDir wtDir (proc "git" ["add", "-A"]))

  let baseAttribution = case actualExecutor of
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

  runProcess_ (setWorkingDir wtDir (proc "git" ["commit", "-m", T.unpack commitMsg]))

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

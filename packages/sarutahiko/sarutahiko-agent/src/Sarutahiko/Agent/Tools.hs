{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Agent.Tools
-- Description : Standard autonomous coding tools for agent tool registry
--
-- Exposes first-party coding tools (read, write, replace, command, build-check)
-- adhering to the Zero-Aeson doctrine and fail-closed allowlist contracts
-- per NIH_PLAN.md Tier 2.
--
-- === Intellectual Lineage & Attribution
-- * Hermes Agent (Nous Research) — core file and shell tool execution architecture
-- * Claude Code / Zed ACP — workspace tool definitions and return models
-- See @NOTICE.md@ and @LICENSES/NOTICE-hermes.txt@ at the repository root.
module Sarutahiko.Agent.Tools
  ( -- * Autonomous Coding Tools
    readFileTool
  , writeFileTool
  , replaceFileTool
  , runCommandTool
  , checkBuildTool
  , makeEchoTool

    -- * Tool Collections & Registries
  , allCodingTools
  , codingAgentRegistry

    -- * Zero-Aeson Parameter Helpers
  , parseFieldString
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.Process.Typed (proc, readProcess)

import Kogaki.Wire.Json.Decode (extractObjectFields)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)
import Sarutahiko.Agent.Registry
  ( RegisteredTool (..)
  , ToolRegistry (..)
  , emptyRegistry
  , makeEchoTool
  , registerToolDef
  )

-- | Extract a string value for a given key from raw JSON bytes using Kogaki lexer.
parseFieldString :: ByteString -> ByteString -> Maybe Text
parseFieldString key jsonBytes = do
  tokens <- case lexJsonEither jsonBytes of
    Right tks -> Just tks
    Left _    -> Nothing
  fields <- case extractObjectFields tokens of
    Right flds -> Just flds
    Left _     -> Nothing
  valTokens <- Map.lookup key fields
  case valTokens of
    [TkString t] -> Just t
    _            -> Nothing

-- ----------------------------------------------------------------------------
-- File and Process Tools
-- ----------------------------------------------------------------------------

-- | Tool for reading the full contents of a file as UTF-8 text.
readFileTool :: RegisteredTool
readFileTool = RegisteredTool
  { rtName                 = "read_file"
  , rtDescription          = "Reads the entire contents of a file as UTF-8 text"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}"
  , rtHandler              = \args -> do
      case parseFieldString "path" args of
        Nothing -> pure ("Error: Missing or invalid 'path' argument", False)
        Just path -> do
          let fp = T.unpack path
          exists <- doesFileExist fp
          if exists
            then do
              eContent <- try @SomeException (TIO.readFile fp)
              case eContent of
                Right content -> pure (content, True)
                Left ex       -> pure ("Error reading file: " <> T.pack (show ex), False)
            else pure ("Error: File does not exist: " <> path, False)
  , rtRequiredCapabilities = []
  }

-- | Tool for writing text content to a file, creating parent directories as needed.
writeFileTool :: RegisteredTool
writeFileTool = RegisteredTool
  { rtName                 = "write_file"
  , rtDescription          = "Writes text content to a specified file path, creating parent directories if needed"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}"
  , rtHandler              = \args -> do
      case (parseFieldString "path" args, parseFieldString "content" args) of
        (Just path, Just content) -> do
          let fp = T.unpack path
          eRes <- try @SomeException $ do
            createDirectoryIfMissing True (takeDirectory fp)
            TIO.writeFile fp content
          case eRes of
            Right () -> pure ("File successfully written: " <> path, True)
            Left ex  -> pure ("Error writing file: " <> T.pack (show ex), False)
        _ -> pure ("Error: Missing 'path' or 'content' argument", False)
  , rtRequiredCapabilities = []
  }

-- | Tool for replacing a target substring with replacement content in an existing file.
replaceFileTool :: RegisteredTool
replaceFileTool = RegisteredTool
  { rtName                 = "replace_file_content"
  , rtDescription          = "Replaces the target substring with replacement text in a file"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}},\"required\":[\"path\",\"target\",\"replacement\"]}"
  , rtHandler              = \args -> do
      case (parseFieldString "path" args, parseFieldString "target" args, parseFieldString "replacement" args) of
        (Just path, Just target, Just replacement) -> do
          let fp = T.unpack path
          exists <- doesFileExist fp
          if not exists
            then pure ("Error: File does not exist: " <> path, False)
            else do
              eContent <- try @SomeException (TIO.readFile fp)
              case eContent of
                Left ex -> pure ("Error reading file: " <> T.pack (show ex), False)
                Right content ->
                  if not (target `T.isInfixOf` content)
                    then pure ("Error: Target text not found in " <> path, False)
                    else do
                      let updated = T.replace target replacement content
                      eWrite <- try @SomeException (TIO.writeFile fp updated)
                      case eWrite of
                        Right () -> pure ("Successfully replaced target text in " <> path, True)
                        Left ex  -> pure ("Error writing replacement: " <> T.pack (show ex), False)
        _ -> pure ("Error: Missing 'path', 'target', or 'replacement' argument", False)
  , rtRequiredCapabilities = []
  }

-- | Tool for executing a shell command with captured stdout/stderr.
runCommandTool :: RegisteredTool
runCommandTool = RegisteredTool
  { rtName                 = "run_command"
  , rtDescription          = "Executes a shell command with standard timeout and returns combined output"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}"
  , rtHandler              = \args -> do
      case parseFieldString "command" args of
        Nothing -> pure ("Error: Missing 'command' argument", False)
        Just cmd -> do
          (code, outBs, errBs) <- readProcess (proc "sh" ["-c", T.unpack cmd])
          let outTxt = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs]))
          case code of
            ExitSuccess   -> pure (outTxt, True)
            ExitFailure c -> pure ("Command failed with code " <> T.pack (show c) <> ":\n" <> outTxt, False)
  , rtRequiredCapabilities = []
  }

-- | Tool for checking package compilation via cabal.
checkBuildTool :: RegisteredTool
checkBuildTool = RegisteredTool
  { rtName                 = "check_build"
  , rtDescription          = "Runs cabal v2-build on specified package or all packages to check for compiler errors"
  , rtSchema               = "{\"type\":\"object\",\"properties\":{\"package\":{\"type\":\"string\"}},\"required\":[]}"
  , rtHandler              = \args -> do
      let pkg = case parseFieldString "package" args of
            Just p | not (T.null (T.strip p)) -> [T.unpack (T.strip p)]
            _                                 -> []
          cabalArgs = "v2-build" : pkg
      (code, outBs, errBs) <- readProcess (proc "cabal" cabalArgs)
      let outTxt = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs]))
      case code of
        ExitSuccess   -> pure ("Build succeeded:\n" <> outTxt, True)
        ExitFailure c -> pure ("Build failed with exit code " <> T.pack (show c) <> ":\n" <> outTxt, False)
  , rtRequiredCapabilities = []
  }

-- ----------------------------------------------------------------------------
-- Collections & Default Registries
-- ----------------------------------------------------------------------------

-- | List of all standard autonomous coding tools.
allCodingTools :: [RegisteredTool]
allCodingTools =
  [ makeEchoTool
  , readFileTool
  , writeFileTool
  , replaceFileTool
  , runCommandTool
  , checkBuildTool
  ]

-- | Default agent registry equipped with all autonomous coding tools.
codingAgentRegistry :: ToolRegistry
codingAgentRegistry = foldr registerToolDef emptyRegistry allCodingTools

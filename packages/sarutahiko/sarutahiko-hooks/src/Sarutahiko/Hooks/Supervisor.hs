{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.Hooks.Supervisor
-- Description : Subprocess hook supervisor with fail-closed timeout enforcement
--
-- Executes external hooks over stdin/stdout JSON wire protocol with strict
-- deadline supervision per NIH_PLAN.md Tier 2 (sarutahiko-hooks).
module Sarutahiko.Hooks.Supervisor
  ( executeHook
  , runInProcessHook
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, SomeException, catch, finally, try)
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Exit (ExitCode (..))
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process.Typed
  ( byteStringInput
  , byteStringOutput
  , getPid
  , getStderr
  , getStdout
  , proc
  , setStderr
  , setStdin
  , setStdout
  , waitExitCode
  , withProcessTerm
  )

import Sarutahiko.Hooks.Types
  ( HookContext (..)
  , HookResult (..)
  , HookSpec (..)
  , decodeHookResult
  , encodeHookContext
  )

-- | Execute an external hook subprocess with stdin JSON and fail-closed timeout.
executeHook :: HookSpec -> HookContext -> IO HookResult
executeHook spec ctx = do
  start <- getCurrentTime
  let timeoutMicros = max 1 (hsTimeoutSec spec) * 1000000
      stdinBytes = BSL.fromStrict (encodeHookContext ctx)
      processCmd = setStdin (byteStringInput stdinBytes)
                 $ setStdout byteStringOutput
                 $ setStderr byteStringOutput
                 $ proc (hsCommand spec) (map T.unpack (hsArgs spec))

  timedOutRef <- newIORef False
  mRes <- try @SomeException $ withProcessTerm processCmd $ \p -> do
    wTid <- forkIO $ do
      threadDelay timeoutMicros
      writeIORef timedOutRef True
      mPid <- getPid p
      case mPid of
        Just pid -> catch (signalProcess sigKILL pid) (\(_ :: IOException) -> pure ())
        Nothing  -> pure ()
    (`finally` killThread wTid) $ do
      code <- waitExitCode p
      outBs <- atomically (getStdout p)
      errBs <- atomically (getStderr p)
      timedOut <- readIORef timedOutRef
      pure (timedOut, code, outBs, errBs)

  end <- getCurrentTime
  let elapsedMs = round (diffUTCTime end start * 1000)

  case mRes of
    Left err ->
      pure HookResult
        { hrSuccess   = hsAllowFail spec
        , hrOutput    = ""
        , hrError     = Just ("Failed to launch hook process: " <> T.pack (show err))
        , hrElapsedMs = elapsedMs
        }

    Right (True, _code, _outBs, _errBs) ->
      pure HookResult
        { hrSuccess   = False
        , hrOutput    = ""
        , hrError     = Just ("Hook timed out after " <> T.pack (show (hsTimeoutSec spec)) <> "s")
        , hrElapsedMs = elapsedMs
        }

    Right (False, ExitSuccess, outBs, _errBs) -> do
      let outStrict = BSL.toStrict outBs
      case decodeHookResult outStrict of
        Right hr -> pure hr { hrElapsedMs = elapsedMs }
        Left _ ->
          pure HookResult
            { hrSuccess   = True
            , hrOutput    = TE.decodeUtf8With TEE.lenientDecode outStrict
            , hrError     = Nothing
            , hrElapsedMs = elapsedMs
            }

    Right (False, ExitFailure code, outBs, errBs) -> do
      let errText = TE.decodeUtf8With TEE.lenientDecode (BSL.toStrict (BSL.concat [outBs, "\n", errBs]))
      pure HookResult
        { hrSuccess   = hsAllowFail spec
        , hrOutput    = ""
        , hrError     = Just ("Hook exited with code " <> T.pack (show code) <> ": " <> errText)
        , hrElapsedMs = elapsedMs
        }

-- | Run an in-process hook callback with synthetic context.
runInProcessHook :: (HookContext -> IO (Bool, Text)) -> HookContext -> IO HookResult
runInProcessHook handler ctx = do
  start <- getCurrentTime
  (ok, out) <- handler ctx
  end <- getCurrentTime
  let elapsedMs = round (diffUTCTime end start * 1000)
  pure HookResult
    { hrSuccess   = ok
    , hrOutput    = out
    , hrError     = if ok then Nothing else Just out
    , hrElapsedMs = elapsedMs
    }

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Sarutahiko.Effect.Interpreter.Polysemy
-- Description : Polysemy seam compatibility interpreters for core signatures
module Sarutahiko.Effect.Interpreter.Polysemy
  ( -- * Clock Interpreters
    runClockPurePoly
  , runClockIOPoly

    -- * Resource Interpreters
  , runResourcePurePoly
  , runResourceIOPoly

    -- * Process Interpreters
  , runProcessMockPoly
  , runProcessIOPoly

    -- * Log Interpreters
  , runLogPurePoly
  , runLogIOPoly

    -- * Smart Senders
  , getCurrentTimePoly
  , getMonotonicTimePoly
  , sleepPoly
  , allocatePoly
  , releasePoly
  , logEntryPoly
  ) where

import Control.Concurrent (threadDelay)
import Data.IORef (IORef, modifyIORef', readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import System.Exit (ExitCode (..))

import qualified Polysemy as P

import Sarutahiko.Effect.Clock (Clock (..))
import Sarutahiko.Effect.Interpreter.Effectful
  ( LoggedRecord (..)
  , MockProcessState (..)
  )
import Sarutahiko.Effect.Log (Log (..), LogSeverity (..), SomeRow (..))
import Sarutahiko.Effect.Process
  ( ChildHandle (..)
  , ChildProcessId (..)
  , Process (..)
  , ProcessConfig (..)
  )
import Sarutahiko.Effect.Resource (Resource (..), ResourceKey (..))
import Sarutahiko.Process.Capability (MonadProcess (..))
import qualified Sarutahiko.Process.Supervisor as Sup

instance (P.Member Process r) => MonadProcess (P.Sem r) where
  spawnChild        = P.send . SpawnChild
  readStdout        = P.send . ReadStdout
  writeStdin h bs   = P.send (WriteStdin h bs)
  waitChild         = P.send . WaitChild
  pollChild         = P.send . PollChild
  killChild h sig   = P.send (KillChild h sig)
  closeChildHandles = P.send . CloseChildHandles

getCurrentTimePoly :: (P.Member Clock r) => P.Sem r UTCTime
getCurrentTimePoly = P.send GetCurrentTime

getMonotonicTimePoly :: (P.Member Clock r) => P.Sem r Double
getMonotonicTimePoly = P.send GetMonotonicTime

sleepPoly :: (P.Member Clock r) => NominalDiffTime -> P.Sem r ()
sleepPoly = P.send . Sleep

allocatePoly :: (P.Member Resource r) => P.Sem r () -> P.Sem r ResourceKey
allocatePoly = P.send . Allocate

releasePoly :: (P.Member Resource r) => ResourceKey -> P.Sem r ()
releasePoly = P.send . Release

logEntryPoly :: (P.Member Log r) => LogSeverity -> SomeRow -> P.Sem r ()
logEntryPoly sev r = P.send (LogEntry sev r)

runClockPurePoly
  :: (P.Member (P.Embed IO) r)
  => UTCTime
  -> IORef Double
  -> P.Sem (Clock : r) a
  -> P.Sem r a
runClockPurePoly fixedUtc timeRef = P.interpret $ \case
  GetCurrentTime   -> pure fixedUtc
  GetMonotonicTime -> P.embed $ readIORef timeRef
  Sleep dt         -> P.embed $ modifyIORef' timeRef (+ realToFrac dt)

runClockIOPoly :: (P.Member (P.Embed IO) r) => P.Sem (Clock : r) a -> P.Sem r a
runClockIOPoly = P.interpret $ \case
  GetCurrentTime   -> P.embed getCurrentTime
  GetMonotonicTime -> P.embed getMonotonicTime
  Sleep dt         -> P.embed $ threadDelay (round (nominalDiffTimeToSeconds dt * 1e6))

runResourcePurePoly
  :: (P.Member (P.Embed IO) r)
  => IORef [Text]
  -> P.Sem (Resource : r) a
  -> P.Sem r a
runResourcePurePoly logRef = P.interpretH $ \case
  Allocate finalizer -> do
    let key = ResourceKey 100
    P.embed $ modifyIORef' logRef (\s -> "allocated:100" : s)
    f' <- P.runT finalizer
    _ <- P.raise (runResourcePurePoly logRef f')
    P.pureT key
  Release (ResourceKey k) -> do
    P.embed $ modifyIORef' logRef (\s -> ("released:" <> showText k) : s)
    P.pureT ()
  where
    showText :: Word64 -> Text
    showText = T.pack . show

runResourceIOPoly :: P.Sem (Resource : r) a -> P.Sem r a
runResourceIOPoly = P.interpretH $ \case
  Allocate finalizer -> do
    f' <- P.runT finalizer
    _ <- P.raise (runResourceIOPoly f')
    P.pureT (ResourceKey 1)
  Release _ -> P.pureT ()

runProcessMockPoly
  :: (P.Member (P.Embed IO) r)
  => IORef MockProcessState
  -> P.Sem (Process : r) a
  -> P.Sem r a
runProcessMockPoly ref = P.interpret $ \case
  SpawnChild cfg -> P.embed $ do
    st <- readIORef ref
    let newId = mockSpawnCount st + 1
        fakeOutput = "mock_output_for:" <> TE.encodeUtf8 (T.pack (cmdPath cfg))
        newProcs = Map.insert newId (cfg, fakeOutput, ExitSuccess) (mockProcesses st)
    writeIORef ref (MockProcessState newId newProcs)
    pure (ChildHandle (ChildProcessId newId) cfg)
  ReadStdout (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, out, _) -> pure out
      Nothing          -> pure ""
  WriteStdin _ _ -> pure ()
  WaitChild (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure code
      Nothing           -> pure (ExitFailure 1)
  PollChild (ChildHandle (ChildProcessId cid) _) -> P.embed $ do
    st <- readIORef ref
    case Map.lookup cid (mockProcesses st) of
      Just (_, _, code) -> pure (Just code)
      Nothing           -> pure (Just (ExitFailure 1))
  KillChild (ChildHandle (ChildProcessId cid) _) _ -> P.embed $ do
    modifyIORef' ref $ \st ->
      st { mockProcesses = Map.delete cid (mockProcesses st) }
  CloseChildHandles _ -> pure ()

runProcessIOPoly
  :: (P.Member (P.Embed IO) r)
  => Sup.ProcessTable
  -> P.Sem (Process : r) a
  -> P.Sem r a
runProcessIOPoly pt = P.interpret $ \case
  SpawnChild cfg        -> P.embed $ Sup.spawnProcessIO pt cfg
  ReadStdout h          -> P.embed $ Sup.readStdoutIO pt h
  WriteStdin h bs       -> P.embed $ Sup.writeStdinIO pt h bs
  WaitChild h           -> P.embed $ Sup.waitChildIO pt h
  PollChild h           -> P.embed $ Sup.pollChildIO pt h
  KillChild h sig       -> P.embed $ Sup.killChildIO pt h sig
  CloseChildHandles h   -> P.embed $ Sup.closeChildHandlesIO pt h

runLogPurePoly
  :: (P.Member (P.Embed IO) r)
  => IORef [LoggedRecord]
  -> P.Sem (Log : r) a
  -> P.Sem r a
runLogPurePoly ref = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    modifyIORef' ref (LoggedRecord sev tag :)

runLogIOPoly :: (P.Member (P.Embed IO) r) => P.Sem (Log : r) a -> P.Sem r a
runLogIOPoly = P.interpret $ \case
  LogEntry sev (SomeRow tag _) -> P.embed $ do
    putStrLn $ "[" ++ show sev ++ "] " ++ T.unpack tag

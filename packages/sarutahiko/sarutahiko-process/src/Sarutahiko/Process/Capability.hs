{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module      : Sarutahiko.Process.Capability
-- Description : Tagless-final capability typeclass for process operations (Façade Pattern)
module Sarutahiko.Process.Capability
  ( MonadProcess (..)
  , withSupervisedChild
  ) where

import Control.Monad.Catch (MonadMask, bracket)
import Data.ByteString (ByteString)
import System.Exit (ExitCode)

import Sarutahiko.Effect.Process
  ( ChildHandle
  , ProcessConfig
  , ProcessSignal (..)
  )

-- | Open tagless capability typeclass exposing subprocess supervision.
class Monad m => MonadProcess m where
  spawnChild        :: ProcessConfig -> m ChildHandle
  readStdout        :: ChildHandle -> m ByteString
  writeStdin        :: ChildHandle -> ByteString -> m ()
  waitChild         :: ChildHandle -> m ExitCode
  pollChild         :: ChildHandle -> m (Maybe ExitCode)
  killChild         :: ChildHandle -> ProcessSignal -> m ()
  closeChildHandles :: ChildHandle -> m ()

-- | Resource-bracketed child process runner ensuring handles are closed
-- and processes terminated if an exception or short-circuit occurs.
withSupervisedChild
  :: (MonadProcess m, MonadMask m)
  => ProcessConfig
  -> (ChildHandle -> m a)
  -> m a
withSupervisedChild cfg = bracket
  (spawnChild cfg)
  (\h -> do
    closeChildHandles h
    killChild h SigTerm
  )

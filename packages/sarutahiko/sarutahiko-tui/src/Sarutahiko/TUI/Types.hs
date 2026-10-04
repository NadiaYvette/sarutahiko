{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.TUI.Types
-- Description : Core state models and events for the terminal user interface
--
-- Pure state representations and event algebra for the terminal UI,
-- supporting streaming token display and keypress cancellation.
module Sarutahiko.TUI.Types
  ( -- * UI Lifecycle Status
    TuiStatus (..)
    -- * Messages and State
  , TuiMessage (..)
  , TuiState (..)
  , initialTuiState
    -- * UI Events
  , TuiEvent (..)
    -- * UI Actions (Command Outputs)
  , TuiAction (..)
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Current operational status of the TUI.
data TuiStatus
  = TuiIdle
  | TuiWaitingInput
  | TuiStreaming
  | TuiCancelled
  deriving stock (Eq, Ord, Show, Generic)

-- | Rendered message in the conversation viewport.
data TuiMessage = TuiMessage
  { msgRole    :: !Text
  , msgContent :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Complete UI state record.
data TuiState = TuiState
  { tsSessionId      :: !Text
  , tsStatus         :: !TuiStatus
  , tsInputBuffer    :: !Text
  , tsHistory        :: ![TuiMessage]
  , tsActiveResponse :: !Text
  , tsScrollOffset   :: !Int
  } deriving stock (Eq, Show, Generic)

-- | Construct an empty initial UI state for a session.
initialTuiState :: Text -> TuiState
initialTuiState sid = TuiState
  { tsSessionId      = sid
  , tsStatus         = TuiWaitingInput
  , tsInputBuffer    = ""
  , tsHistory        = []
  , tsActiveResponse = ""
  , tsScrollOffset   = 0
  }

-- | Input and lifecycle events delivered to the TUI event loop.
data TuiEvent
  = EvChar !Char
  | EvBackspace
  | EvEnter
  | EvCancel
  | EvTokenChunk !Text
  | EvTurnCompleted
  deriving stock (Eq, Show, Generic)

-- | Outgoing action requests triggered by user interactions.
data TuiAction
  = ActNone
  | ActSubmitPrompt !Text
  | ActSendCancel
  | ActRedraw
  deriving stock (Eq, Show, Generic)

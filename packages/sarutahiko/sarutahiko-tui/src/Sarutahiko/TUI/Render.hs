{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.TUI.Render
-- Description : Pure layout and declarative rendering for the terminal UI
--
-- Formats the UI state into structured terminal buffers with headers,
-- conversation history, streaming token indicators, and input prompt.
module Sarutahiko.TUI.Render
  ( renderTuiView
  , renderHeader
  , renderMessage
  , renderInputBar
  , renderStatusBar
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Sarutahiko.TUI.Types

-- | Render the full screen view for the current 'TuiState'.
renderTuiView :: Int -> Int -> TuiState -> Text
renderTuiView width _height st =
  T.unlines
    [ renderHeader width (tsSessionId st) (tsStatus st)
    , T.replicate width "─"
    , renderHistory (tsHistory st) (tsActiveResponse st) (tsStatus st)
    , T.replicate width "─"
    , renderInputBar (tsInputBuffer st)
    , renderStatusBar width (tsStatus st)
    ]

-- | Top header with title, session id, and current status.
renderHeader :: Int -> Text -> TuiStatus -> Text
renderHeader _width sid status =
  "┌─ [Sarutahiko TUI] Session: " <> sid <> " │ Status: " <> statusText status <> " ─┐"
  where
    statusText TuiIdle         = "IDLE"
    statusText TuiWaitingInput = "WAITING INPUT"
    statusText TuiStreaming    = "STREAMING..."
    statusText TuiCancelled    = "CANCELLED"

-- | Render conversation history plus active streaming buffer.
renderHistory :: [TuiMessage] -> Text -> TuiStatus -> Text
renderHistory msgs activeResp status =
  let renderedHistory = map renderMessage msgs
      activeBlock =
        if T.null activeResp && status /= TuiStreaming
          then []
          else [ "Assistant: " <> activeResp <> (if status == TuiStreaming then " ▌" else "") ]
  in T.unlines (renderedHistory ++ activeBlock)

-- | Format an individual message line.
renderMessage :: TuiMessage -> Text
renderMessage (TuiMessage role content) =
  "[" <> role <> "] " <> content

-- | Input line with prompt prefix.
renderInputBar :: Text -> Text
renderInputBar buf =
  "> " <> buf <> "█"

-- | Status line with navigation hints.
renderStatusBar :: Int -> TuiStatus -> Text
renderStatusBar _width status =
  let hint = case status of
        TuiStreaming -> "Press [Esc] to cancel turn"
        _            -> "Type prompt and press [Enter] to submit │ [Esc]: cancel"
  in "└─ " <> hint <> " ─┘"

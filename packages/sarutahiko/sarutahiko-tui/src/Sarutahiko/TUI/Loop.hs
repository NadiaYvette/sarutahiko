{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.TUI.Loop
-- Description : Pure event stepping and JSON-RPC request formatting for the TUI
--
-- Pure state machine handling user keypresses, streaming token updates,
-- cancellation requests, and turn finalization.
module Sarutahiko.TUI.Loop
  ( stepTui
  , formatTurnRequest
  , formatCancelNotification
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Sarutahiko.TUI.Types

-- | Step the TUI state in response to an event, returning updated state and action.
stepTui :: TuiEvent -> TuiState -> (TuiState, TuiAction)
stepTui ev st = case ev of
  EvChar c ->
    let !newBuf = tsInputBuffer st `T.snoc` c
    in (st { tsInputBuffer = newBuf }, ActRedraw)

  EvBackspace ->
    let !newBuf = if T.null (tsInputBuffer st)
          then ""
          else T.init (tsInputBuffer st)
    in (st { tsInputBuffer = newBuf }, ActRedraw)

  EvEnter ->
    let prompt = T.strip (tsInputBuffer st)
    in if T.null prompt
         then (st, ActNone)
         else
           let userMsg = TuiMessage { msgRole = "User", msgContent = prompt }
               !st' = st
                 { tsInputBuffer    = ""
                 , tsStatus         = TuiStreaming
                 , tsHistory        = tsHistory st ++ [userMsg]
                 , tsActiveResponse = ""
                 }
           in (st', ActSubmitPrompt prompt)

  EvCancel ->
    if tsStatus st == TuiStreaming
      then
        let cancelledMsg = TuiMessage
              { msgRole    = "Assistant"
              , msgContent = tsActiveResponse st <> " [Cancelled by user]"
              }
            !st' = st
              { tsStatus         = TuiCancelled
              , tsHistory        = tsHistory st ++ [cancelledMsg]
              , tsActiveResponse = ""
              }
        in (st', ActSendCancel)
      else (st, ActNone)

  EvTokenChunk chunk ->
    let !newResp = tsActiveResponse st <> chunk
    in (st { tsActiveResponse = newResp, tsStatus = TuiStreaming }, ActRedraw)

  EvTurnCompleted ->
    let finalMsg = TuiMessage
          { msgRole    = "Assistant"
          , msgContent = tsActiveResponse st
          }
        !st' = st
          { tsStatus         = TuiWaitingInput
          , tsHistory        = if T.null (tsActiveResponse st)
                                 then tsHistory st
                                 else tsHistory st ++ [finalMsg]
          , tsActiveResponse = ""
          }
    in (st', ActRedraw)

-- | Construct a JSON-RPC 2.0 request byte string for an agent turn.
formatTurnRequest :: Int64 -> Text -> Text -> ByteString
formatTurnRequest reqId sid prompt =
  let safeSid = escapeJsonText sid
      safePrompt = escapeJsonText prompt
  in "{\"jsonrpc\":\"2.0\",\"id\":" <> BSC.pack (show reqId)
     <> ",\"method\":\"agent/turn\",\"params\":{\"sessionId\":\""
     <> safeSid <> "\",\"prompt\":\"" <> safePrompt <> "\"}}"

-- | Construct a JSON-RPC 2.0 cancellation notification byte string.
formatCancelNotification :: Text -> ByteString
formatCancelNotification sid =
  let safeSid = escapeJsonText sid
  in "{\"jsonrpc\":\"2.0\",\"method\":\"agent/cancel\",\"params\":{\"sessionId\":\""
     <> safeSid <> "\"}}"

-- | Helper escaping JSON special characters.
escapeJsonText :: Text -> ByteString
escapeJsonText txt = TE.encodeUtf8 $ T.concatMap escapeChar txt
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = T.singleton c

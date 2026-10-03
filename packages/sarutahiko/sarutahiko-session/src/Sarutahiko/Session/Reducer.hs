{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Session.Reducer
-- Description : Conversation-tail reducer and prompt-cache prefix hash computation
--
-- Pure fold over the event stream hydrating 'SessionContext' and calculating
-- deterministic prompt-cache prefix hashes per MEMORY_ENGINE_DESIGN.md §3.1.
module Sarutahiko.Session.Reducer
  ( reduceSessionEvent
  , reduceSessionEvents
  , computePrefixHash
  , computeMessagesPrefixHash
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Sarutahiko.Effect.EventStore (SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.ModelAPI (Message (..), Role (..))
import Sarutahiko.Session.Types
  ( SessionContext (..)
  , decodeMessagePayload
  , decodeSessionClosed
  , decodeSessionOpened
  , decodeToolObserved
  , emptySessionContext
  , fnv1a64Hex
  , mpContent
  , mpRole
  , scReason
  , soCwd
  , soModel
  , toCallId
  , toOk
  , toOutput
  )

-- | Reduce a single 'StoredEvent' into 'SessionContext'.
-- Adheres to MEMORY_ENGINE_DESIGN.md §3.2.2: fail-closed over unknown event kinds.
reduceSessionEvent :: SessionContext -> StoredEvent -> SessionContext
reduceSessionEvent ctx ev = case eventType ev of
  "session_opened" -> case decodeSessionOpened (eventPayload ev) of
    Right p -> ctx { scModel = soModel p, scCwd = soCwd p }
    Left _  -> ctx
  "message" -> case decodeMessagePayload (eventPayload ev) of
    Right p -> ctx { scMessages = scMessages ctx ++ [Message (mpRole p) (mpContent p)] }
    Left _  -> ctx
  "tool_invoked" -> ctx -- Tool invocation logged; causal tree tracking
  "tool_observed" -> case decodeToolObserved (eventPayload ev) of
    Right p -> ctx
      { scToolResults = scToolResults ctx ++ [(toCallId p, toOutput p, toOk p)]
      , scMessages    = scMessages ctx ++ [Message RoleTool (toOutput p)]
      }
    Left _  -> ctx
  "session_closed" -> case decodeSessionClosed (eventPayload ev) of
    Right p -> ctx { scIsClosed = True, scCloseReason = Just (scReason p) }
    Left _  -> ctx { scIsClosed = True }
  _ -> ctx

-- | Pure fold walking the session event stream, reconstructing active context
-- and computing deterministic prompt-cache prefix hash.
reduceSessionEvents :: SessionId -> [StoredEvent] -> SessionContext
reduceSessionEvents sid evs =
  let initial = emptySessionContext sid
      reduced = foldl reduceSessionEvent initial evs
  in reduced { scPrefixHash = computePrefixHash reduced }

-- | Compute deterministic prompt-cache prefix hash for a 'SessionContext'.
computePrefixHash :: SessionContext -> Text
computePrefixHash ctx =
  let modelBytes = TE.encodeUtf8 (scModel ctx)
      cwdBytes   = TE.encodeUtf8 (T.pack (scCwd ctx))
      msgsBytes  = messagesToBytes (scMessages ctx)
      payload    = modelBytes <> "\n" <> cwdBytes <> "\n" <> msgsBytes
  in fnv1a64Hex payload

-- | Compute deterministic prefix hash over a list of messages.
computeMessagesPrefixHash :: [Message] -> Text
computeMessagesPrefixHash msgs = fnv1a64Hex (messagesToBytes msgs)

messagesToBytes :: [Message] -> BS.ByteString
messagesToBytes msgs =
  BS.intercalate "\n"
    [ roleToBytes (msgRole m) <> ":" <> TE.encodeUtf8 (msgContent m)
    | m <- msgs
    ]

roleToBytes :: Role -> BS.ByteString
roleToBytes RoleSystem    = "system"
roleToBytes RoleUser      = "user"
roleToBytes RoleAssistant = "assistant"
roleToBytes RoleTool      = "tool"

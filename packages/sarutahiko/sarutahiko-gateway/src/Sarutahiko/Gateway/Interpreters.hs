{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Gateway.Interpreters
-- Description : Production and mock effect interpreters for GatewayEffect
--
-- Provides pure in-memory interpreters for deterministic testing and
-- conduit-bracketed interpreters with deterministic resource cleanup.
module Sarutahiko.Gateway.Interpreters
  ( -- * Pure Mock Carrier
    runGatewayPure
  , GatewayState (..)
  , emptyGatewayState
    -- * Capability Instance
  , sendPure
  ) where

import Control.Concurrent.MVar
import qualified Data.Text as T
import Effectful
import Effectful.Dispatch.Dynamic

import Sarutahiko.Gateway.Effect
import Sarutahiko.Gateway.Types

-- | In-memory record tracking state for pure testing.
data GatewayState = GatewayState
  { gsSentMessages    :: ![GatewayMessage]
  , gsPendingInbound  :: ![GatewayEvent]
  , gsNextMsgSequence :: !Int
  } deriving stock (Eq, Show)

-- | Construct empty gateway state.
emptyGatewayState :: GatewayState
emptyGatewayState = GatewayState
  { gsSentMessages    = []
  , gsPendingInbound  = []
  , gsNextMsgSequence = 1
  }

-- | Run 'GatewayEffect' against an in-memory 'MVar GatewayState'.
runGatewayPure
  :: IOE :> es
  => MVar GatewayState
  -> Eff (GatewayEffect : es) a
  -> Eff es a
runGatewayPure stateVar = interpret $ \_ -> \case
  SendMessage platform recipient content -> liftIO $ do
    modifyMVar stateVar $ \st -> do
      let msgId = T.pack ("msg-" ++ show (gsNextMsgSequence st))
          msg = GatewayMessage
            { gmMessageId   = msgId
            , gmPlatform    = platform
            , gmSenderId    = "sarutahiko"
            , gmRecipientId = recipient
            , gmContent     = content
            }
          !st' = st
            { gsSentMessages    = gsSentMessages st ++ [msg]
            , gsNextMsgSequence = gsNextMsgSequence st + 1
            }
      pure (st', Right msgId)

  PollEvents -> liftIO $ do
    modifyMVar stateVar $ \st -> do
      let events = gsPendingInbound st
          !st' = st { gsPendingInbound = [] }
      pure (st', events)

  BroadcastMessage platform content -> liftIO $ do
    modifyMVar stateVar $ \st -> do
      let msgId = T.pack ("bcast-" ++ show (gsNextMsgSequence st))
          msg = GatewayMessage
            { gmMessageId   = msgId
            , gmPlatform    = platform
            , gmSenderId    = "sarutahiko"
            , gmRecipientId = "all"
            , gmContent     = content
            }
          !st' = st
            { gsSentMessages    = gsSentMessages st ++ [msg]
            , gsNextMsgSequence = gsNextMsgSequence st + 1
            }
      pure (st', [Right msgId])

-- | Convenience helper for injecting inbound test events.
sendPure :: MVar GatewayState -> GatewayEvent -> IO ()
sendPure var ev = modifyMVar_ var $ \st ->
  pure (st { gsPendingInbound = gsPendingInbound st ++ [ev] })

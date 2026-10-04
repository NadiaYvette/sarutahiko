{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Sarutahiko.Gateway.Effect
-- Description : Reified algebraic effect and tagless capability for multi-platform chat
--
-- Expresses chat messaging, inbound event polling, and broadcasting as neutral
-- GADTs and open capability typeclasses under the Façade Pattern per YAMAARASHI_DESIGN.md §4.
module Sarutahiko.Gateway.Effect
  ( -- * Reified Effect GADT
    GatewayEffect (..)
    -- * Tagless Final Capability Typeclass
  , MonadGateway (..)
  , processGatewayMessage
  ) where

import Data.Text (Text)
import Effectful (Dispatch (..), DispatchOf, Effect, Eff, (:>))
import Effectful.Dispatch.Dynamic (send)

import Sarutahiko.Gateway.Types

-- | Reified effect GADT for chat gateway operations.
data GatewayEffect :: Effect where
  -- | Send a message to a recipient on a specific platform.
  SendMessage
    :: !Platform      -- ^ Target platform
    -> !Text          -- ^ Recipient channel or user ID
    -> !Text          -- ^ Text content
    -> GatewayEffect m (Either Text Text)

  -- | Poll available inbound events from active transports.
  PollEvents :: GatewayEffect m [GatewayEvent]

  -- | Broadcast a message to all active channels on a platform.
  BroadcastMessage
    :: !Platform      -- ^ Target platform
    -> !Text          -- ^ Text content
    -> GatewayEffect m [Either Text Text]

type instance DispatchOf GatewayEffect = 'Dynamic

-- | Open capability typeclass for consumers under the Façade Pattern.
class Monad m => MonadGateway m where
  -- | Send a message to a recipient.
  sendGatewayMessage :: Platform -> Text -> Text -> m (Either Text Text)
  -- | Retrieve queued inbound events.
  pollGatewayEvents :: m [GatewayEvent]
  -- | Broadcast a notification across a platform.
  broadcastGatewayMessage :: Platform -> Text -> m [Either Text Text]

-- | Default capability instance for the Eff monad.
instance GatewayEffect :> es => MonadGateway (Eff es) where
  sendGatewayMessage platform recipient content =
    send (SendMessage platform recipient content)
  pollGatewayEvents =
    send PollEvents
  broadcastGatewayMessage platform content =
    send (BroadcastMessage platform content)

-- | Process an incoming gateway event through an assistant turn handler,
-- automatically dispatching the resulting response back to the sender channel.
processGatewayMessage
  :: MonadGateway m
  => GatewayEvent
  -> (Text -> m Text) -- ^ Autonomous turn handler taking prompt and producing response
  -> m (Maybe (Either Text Text))
processGatewayMessage ev handler = case ev of
  EvMessageReceived msg -> do
    resp <- handler (gmContent msg)
    res <- sendGatewayMessage (gmPlatform msg) (gmSenderId msg) resp
    pure (Just res)
  EvConnectionOpened _ _ -> pure Nothing
  EvConnectionClosed _ _ -> pure Nothing

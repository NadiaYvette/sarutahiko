{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Utai.Capability
-- Description : Tagless capability typeclass for ModelAPI (Façade Pattern)
--
-- Exposes the open 'MonadModelAPI' typeclass per DECISION-002, decoupling
-- high-level turn programs and agent loops from concrete effect systems.
module Utai.Capability
  ( MonadModelAPI (..)
  , completeText
  , streamText
  ) where

import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, (:>))
import Effectful.Dispatch.Dynamic (send)

import Sarutahiko.Effect.ModelAPI
import Sarutahiko.Effect.Stepper (Stepper)

-- | Dynamic dispatch instance for Effectful.
type instance DispatchOf ModelAPI = Dynamic

-- | Open tagless-final capability for LLM operations.
class Monad m => MonadModelAPI m where
  complete    :: CompletionReq -> m CompletionResp
  stream      :: CompletionReq -> m (Stepper m StreamEvent)
  embed       :: EmbedReq -> m EmbedResp
  countTokens :: [Message] -> m TokenCount

-- | Convenient helper to complete single-prompt text with default options.
completeText :: MonadModelAPI m => Text -> Text -> m Text
completeText model prompt = do
  let req = CompletionReq
        { reqModel    = model
        , reqMessages = [Message RoleUser prompt]
        , reqTools    = []
        , reqOptions  = defaultModelOptions
        }
  respContent <$> complete req

-- | Convenient helper to stream single-prompt text with default options.
streamText :: MonadModelAPI m => Text -> Text -> m (Stepper m StreamEvent)
streamText model prompt = do
  let req = CompletionReq
        { reqModel    = model
        , reqMessages = [Message RoleUser prompt]
        , reqTools    = []
        , reqOptions  = defaultModelOptions
        }
  stream req

-- | Façade Pattern: Automatic instance for 'Eff es' when 'ModelAPI :> es'.
instance (ModelAPI :> es) => MonadModelAPI (Eff es) where
  complete req   = send (Complete req)
  stream req     = send (Stream req)
  embed req      = send (Embed req)
  countTokens ms = send (Count ms)

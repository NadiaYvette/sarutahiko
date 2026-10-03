{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Hashigakari.Sqlite.Capability
-- Description : Tagless capability instances for EventStore and TaskQueue (Façade Pattern)
--
-- Binds 'Eff es' to the open 'MonadEventStore' and 'MonadTaskQueue' capability
-- typeclasses via the underlying reified GADTs per DECISION-002 and DECISION-003.
module Hashigakari.Sqlite.Capability
  ( MonadEventStore (..)
  , MonadTaskQueue (..)
  ) where

import Effectful
import Effectful.Dispatch.Dynamic (send)

import Sarutahiko.Effect.EventStore (EventStore (..))
import Sarutahiko.Effect.Interpreter.Effectful ()
import Sarutahiko.Effect.TaskQueue (TaskQueue (..))
import Yamaarashi.Flow.Capability (MonadEventStore (..), MonadTaskQueue (..))

instance (EventStore :> es) => MonadEventStore (Eff es) where
  appendEvent sid evType payload = send (AppendEvent sid evType payload)
  readEvents sid                 = send (ReadEvents sid)

instance (TaskQueue :> es) => MonadTaskQueue (Eff es) where
  enqueueTask tid pkt  = send (EnqueueTask tid pkt)
  claimTask wid        = send (ClaimTask wid)
  completeTask tid res = send (CompleteTask tid res)
  failTask tid err     = send (FailTask tid err)

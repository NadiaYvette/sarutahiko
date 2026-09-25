{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

-- |
-- Module      : Spike
-- Description : Handlers-as-Records spike implementations and benchmarks
--
-- Measures the dynamic dispatch latency overhead of extensible record handlers
-- vs direct GADT pattern-matching interpreters under effectful and polysemy
-- per EFFECT_CATALOG_DESIGN.md §6.2 and PHASE_0_PLAN.md Closure 2.
module Spike
  ( -- * KeyValue Effect
    KeyValue (..)

    -- * Effectful Interpreters
  , KeyValueHandlerEffectful
  , mkKeyValueRecordEffectful
  , runKeyValueDirectEffectful
  , runKeyValueRecordEffectful

    -- * Polysemy Interpreters
  , KeyValueHandlerPolysemy
  , mkKeyValueRecordPolysemy
  , runKeyValueDirectPolysemy
  , runKeyValueRecordPolysemy

    -- * Benchmark Workloads
  , runWorkloadEffectful
  , runWorkloadPolysemy
  ) where

import Control.Monad (replicateM_)
import Data.Functor.Identity (Identity (..))
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Kind (Type)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Record.Anon.Advanced as Anon
import Data.Text (Text)

-- Effectful
import Effectful
import Effectful.Dispatch.Dynamic

-- Polysemy
import qualified Polysemy as P

import Sarutahiko.Records (pattern (:=), Record, emptyRecord)
import Sarutahiko.Records.Combinators (getRecordField)

{-------------------------------------------------------------------------------
  KeyValue Signature
-------------------------------------------------------------------------------}

data KeyValue (m :: Type -> Type) :: Type -> Type where
  GetKV :: !Text -> KeyValue m (Maybe Text)
  PutKV :: !Text -> !Text -> KeyValue m ()

type instance DispatchOf KeyValue = Dynamic

getKV :: (KeyValue :> es) => Text -> Eff es (Maybe Text)
getKV = send . GetKV

putKV :: (KeyValue :> es) => Text -> Text -> Eff es ()
putKV k v = send (PutKV k v)

{-------------------------------------------------------------------------------
  Effectful Interpreters
-------------------------------------------------------------------------------}

-- | Direct handwritten GADT pattern-matching interpreter in effectful
runKeyValueDirectEffectful
  :: (IOE :> es)
  => IORef (Map Text Text)
  -> Eff (KeyValue : es) a
  -> Eff es a
runKeyValueDirectEffectful ref = interpret $ \_ -> \case
  GetKV k   -> liftIO $ Map.lookup k <$> readIORef ref
  PutKV k v -> liftIO $ modifyIORef' ref (Map.insert k v)

-- | Handler record type in effectful
type KeyValueHandlerEffectful es = Record Identity
  '[ "getKV" := (Text -> Eff es (Maybe Text))
   , "putKV" := (Text -> Text -> Eff es ())
   ]

-- | Construct a handler record backed by an IORef
mkKeyValueRecordEffectful
  :: (IOE :> es)
  => IORef (Map Text Text)
  -> KeyValueHandlerEffectful es
mkKeyValueRecordEffectful ref =
  let hGet = Identity (\k -> liftIO (Map.lookup k <$> readIORef ref))
      hPut = Identity (\k v -> liftIO (modifyIORef' ref (Map.insert k v)))
  in Anon.insert #getKV hGet
   $ Anon.insert #putKV hPut
   $ emptyRecord

-- | Handlers-as-records interpreter in effectful
runKeyValueRecordEffectful
  :: KeyValueHandlerEffectful es
  -> Eff (KeyValue : es) a
  -> Eff es a
runKeyValueRecordEffectful handler = interpret $ \_ -> \case
  GetKV k   -> (runIdentity (getRecordField #getKV handler)) k
  PutKV k v -> (runIdentity (getRecordField #putKV handler)) k v

-- | Workload running N iterations of Put and Get
runWorkloadEffectful :: (KeyValue :> es) => Int -> Eff es ()
runWorkloadEffectful n = replicateM_ n $ do
  putKV "benchmark_key" "benchmark_val"
  _ <- getKV "benchmark_key"
  pure ()

{-------------------------------------------------------------------------------
  Polysemy Interpreters
-------------------------------------------------------------------------------}

-- Polysemy effect operations
getKVPoly :: P.Member KeyValue r => Text -> P.Sem r (Maybe Text)
getKVPoly = P.send . GetKV

putKVPoly :: P.Member KeyValue r => Text -> Text -> P.Sem r ()
putKVPoly k v = P.send (PutKV k v)

-- | Direct handwritten GADT pattern-matching interpreter in polysemy
runKeyValueDirectPolysemy
  :: P.Member (P.Embed IO) r
  => IORef (Map Text Text)
  -> P.Sem (KeyValue : r) a
  -> P.Sem r a
runKeyValueDirectPolysemy ref = P.interpret $ \case
  GetKV k   -> P.embed $ Map.lookup k <$> readIORef ref
  PutKV k v -> P.embed $ modifyIORef' ref (Map.insert k v)

-- | Handler record type in polysemy
type KeyValueHandlerPolysemy r = Record Identity
  '[ "getKV" := (Text -> P.Sem r (Maybe Text))
   , "putKV" := (Text -> Text -> P.Sem r ())
   ]

-- | Construct a handler record for polysemy
mkKeyValueRecordPolysemy
  :: P.Member (P.Embed IO) r
  => IORef (Map Text Text)
  -> KeyValueHandlerPolysemy r
mkKeyValueRecordPolysemy ref =
  let hGet = Identity (\k -> P.embed (Map.lookup k <$> readIORef ref))
      hPut = Identity (\k v -> P.embed (modifyIORef' ref (Map.insert k v)))
  in Anon.insert #getKV hGet
   $ Anon.insert #putKV hPut
   $ emptyRecord

-- | Handlers-as-records interpreter in polysemy
runKeyValueRecordPolysemy
  :: KeyValueHandlerPolysemy r
  -> P.Sem (KeyValue : r) a
  -> P.Sem r a
runKeyValueRecordPolysemy handler = P.interpret $ \case
  GetKV k   -> (runIdentity (getRecordField #getKV handler)) k
  PutKV k v -> (runIdentity (getRecordField #putKV handler)) k v

-- | Workload running N iterations in polysemy
runWorkloadPolysemy :: P.Member KeyValue r => Int -> P.Sem r ()
runWorkloadPolysemy n = replicateM_ n $ do
  putKVPoly "benchmark_key" "benchmark_val"
  _ <- getKVPoly "benchmark_key"
  pure ()

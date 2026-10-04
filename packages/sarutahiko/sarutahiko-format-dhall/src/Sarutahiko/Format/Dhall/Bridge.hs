{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Format.Dhall.Bridge
-- Description : Row-typed Dhall configuration bridge to large-anon records
--
-- Maps Dhall's typed record configurations directly to 'large-anon' extensible
-- records without rewriting the upstream evaluator per HASHIGAKARI_DESIGN.md
-- and DECISION-004.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'dhall' (Gabriel Gonzalez) — typed record language
-- * 'large-anon' (Edsko de Vries / Well-Typed) — extensible anonymous records
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Format.Dhall.Bridge
  ( -- * High-Level Bridge Evaluation
    evalDhallRow
  , evalDhallRowText
  , renderDhallRow
    -- * Dictionary Mappings
  , recordFromDhallMap
  , recordToDhallMap
  ) where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Record.Anon (AllFields, K (..), KnownFields, (:.:) (..))
import qualified Data.Record.Anon.Advanced as Anon
import Data.Record.Anon.Advanced (Record, cmap, collapse, reifyKnownFields)
import Data.Text (Text)
import qualified Data.Text as T

import Sarutahiko.Format.Dhall.Parser (parseDhallRecord)
import Sarutahiko.Format.Dhall.Render (renderDhallRecord)
import Sarutahiko.Format.Dhall.Types
  ( DhallError (..)
  , DhallValue (..)
  , FromDhallValue (..)
  , ToDhallValue (..)
  )

-- | Parse and evaluate a Dhall configuration string into an extensible record in IO.
evalDhallRow
  :: forall r. (KnownFields r, AllFields r FromDhallValue)
  => Text
  -> IO (Either DhallError (Record Identity r))
evalDhallRow = pure . evalDhallRowText

-- | Pure version of 'evalDhallRow' parsing and evaluating a Dhall record string.
evalDhallRowText
  :: forall r. (KnownFields r, AllFields r FromDhallValue)
  => Text
  -> Either DhallError (Record Identity r)
evalDhallRowText input = do
  fieldMap <- parseDhallRecord input
  recordFromDhallMap fieldMap

-- | Decode a map of Dhall values into a 'large-anon' 'Record Identity r'.
recordFromDhallMap
  :: forall r. (KnownFields r, AllFields r FromDhallValue)
  => Map Text DhallValue
  -> Either DhallError (Record Identity r)
recordFromDhallMap fieldMap = do
  let namesRecord = reifyKnownFields (Proxy @r)
      decRecord = cmap (Proxy @FromDhallValue) (\(K name) ->
        let colKey = T.pack name
        in case Map.lookup colKey fieldMap of
          Nothing  -> Comp (Left (DhallMissingField colKey))
          Just val -> Comp (Identity <$> fromDhallValue val)
        ) namesRecord
  Anon.sequenceA decRecord

-- | Encode a 'large-anon' 'Record Identity r' into a map of Dhall values.
recordToDhallMap
  :: forall r. (KnownFields r, AllFields r ToDhallValue)
  => Record Identity r
  -> Map Text DhallValue
recordToDhallMap rec =
  let namesRecord = reifyKnownFields (Proxy @r)
      valsRecord = cmap (Proxy @ToDhallValue) (\(Identity v) -> K (toDhallValue v)) rec
      pairsRecord = Anon.zipWith (\(K name) (K dhallVal) -> K (T.pack name, dhallVal)) namesRecord valsRecord
      pairs = collapse pairsRecord
  in Map.fromList pairs

-- | Render an extensible record into valid Dhall record literal syntax.
renderDhallRow
  :: forall r. (KnownFields r, AllFields r ToDhallValue)
  => Record Identity r
  -> Text
renderDhallRow rec = renderDhallRecord (recordToDhallMap rec)

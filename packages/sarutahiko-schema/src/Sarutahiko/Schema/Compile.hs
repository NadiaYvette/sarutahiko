{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Sarutahiko.Schema.Compile
-- Description : Row descriptors to JSON Schema compiler
--
-- Implements Closure 2 (Docrecords Introspection without Reflection):
-- folds anonymous row types at compile time / startup using 'large-anon'
-- into strict 'SchemaNode' descriptors with docrecords extraction.
module Sarutahiko.Schema.Compile
  ( compileRowSchema
  ) where

import Data.Functor.Identity (Identity (..))
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import qualified Data.Text as T

import Data.Record.Anon (AllFields, K (..), KnownFields, Row)
import Data.Record.Anon.Advanced (Record, cmap, collapse, reifyKnownFields)

import Sarutahiko.Schema.Types
  ( KnownFieldSchema (..)
  , KnownRowSchema (..)
  , SchemaNode (..)
  )

-- | Compile an anonymous record row type 'r' into a strict 'SchemaNode'.
-- Populates properties map, filters required fields (excluding optional/TriState),
-- and embeds docstrings from 'DocField' per Invariant 2.
--
-- @since 0.1.0.0
compileRowSchema
  :: forall r. (KnownFields r, AllFields r KnownFieldSchema)
  => Proxy r
  -> SchemaNode
compileRowSchema proxyR =
  let namesRecord = reifyKnownFields proxyR
      fieldDescRecord = cmap (Proxy @KnownFieldSchema)
        (\(K name :: K String a) ->
           let rawNode = fieldToSchema (Proxy @a)
               isOpt   = isFieldOptional (Proxy @a)
               mDoc    = fieldDocString (Proxy @a)
               annotatedNode = case mDoc of
                 Nothing -> rawNode
                 Just d  -> SchemaAnnotated (Just d) rawNode
           in K (T.pack name, annotatedNode, isOpt)
        )
        namesRecord
      descriptors = collapse fieldDescRecord
      props = Map.fromList [ (nm, node) | (nm, node, _) <- descriptors ]
      required = [ nm | (nm, _, opt) <- descriptors, not opt ]
  in SchemaObject props required

-- | Universal instance reflecting any anonymous row satisfying
-- '(KnownFields r, AllFields r KnownFieldSchema)' into 'KnownRowSchema'.
instance (KnownFields r, AllFields r KnownFieldSchema) => KnownRowSchema (r :: Row Type) where
  rowToSchema _ = compileRowSchema (Proxy @r)

-- | Universal instance allowing nested rows to be reflected as 'SchemaObject' fields.
instance (KnownFields r, AllFields r KnownFieldSchema) => KnownFieldSchema (Record Identity (r :: Row Type)) where
  fieldToSchema _ = compileRowSchema (Proxy @r)

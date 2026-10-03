{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Schema.Types
-- Description : JSON Schema AST, row schema classes, and docrecords annotations
--
-- Implements Closure 2 (Docrecords Introspection) and TP-1.3:
-- offline JSON Schema subset representation, row schema reflection,
-- and compile-time docstring extraction.
module Sarutahiko.Schema.Types
  ( -- * Schema AST
    SchemaNode (..)

    -- * Schema Typeclasses
  , KnownRowSchema (..)
  , KnownFieldSchema (..)

    -- * Docrecords Annotation Wrapper
  , DocField (..)

    -- * Wire Serialization
  , schemaNodeToJson
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)

import Data.Record.Anon (Row)
import Kogaki.Wire.Json.Decode (FromJsonField (..), ToJsonField (..))
import Sarutahiko.Records.HKD.TriState (TriState (..))

-- | JSON Schema subset descriptor node.
--
-- @since 0.1.0.0
data SchemaNode
  = SchemaObject !(Map Text SchemaNode) ![Text] -- ^ Properties map and list of required field names
  | SchemaString !(Maybe Text)                  -- ^ String type with optional format/pattern
  | SchemaInteger !(Maybe Int64) !(Maybe Int64) -- ^ Integer type with optional (min, max) bounds
  | SchemaNumber                                -- ^ Arbitrary floating-point number
  | SchemaBoolean                               -- ^ Boolean flag
  | SchemaArray !SchemaNode                     -- ^ Array with item schema
  | SchemaAnnotated !(Maybe Text) !SchemaNode    -- ^ Schema node with docrecords description
  | SchemaRef !Text                             -- ^ Reference string (checked for Invariant 1)
  deriving stock (Eq, Show, Generic)

-- | Reflect a compile-time anonymous row type 'r' into a runtime 'SchemaNode'.
--
-- @since 0.1.0.0
class KnownRowSchema (r :: Row Type) where
  rowToSchema :: proxy r -> SchemaNode

-- | Reflect an individual field type 'a' into a runtime 'SchemaNode'.
--
-- @since 0.1.0.0
class KnownFieldSchema a where
  fieldToSchema   :: proxy a -> SchemaNode
  isFieldOptional :: proxy a -> Bool
  isFieldOptional _ = False
  fieldDocString  :: proxy a -> Maybe Text
  fieldDocString _ = Nothing

-- | Docrecords wrapper annotating a field type 'a' with a compile-time docstring 'doc'.
--
-- @since 0.1.0.0
newtype DocField (doc :: Symbol) a = DocField
  { unDocField :: a
  } deriving stock (Eq, Show, Generic)

instance (KnownSymbol doc, KnownFieldSchema a) => KnownFieldSchema (DocField doc a) where
  fieldToSchema _ = fieldToSchema (Proxy @a)
  isFieldOptional _ = isFieldOptional (Proxy @a)
  fieldDocString _ = Just (T.pack (symbolVal (Proxy @doc)))

instance (FromJsonField a) => FromJsonField (DocField doc a) where
  decodeField mTs = DocField <$> decodeField mTs

instance (ToJsonField a) => ToJsonField (DocField doc a) where
  encodeField (DocField val) = encodeField val

-- ----------------------------------------------------------------------------
-- Base KnownFieldSchema Instances
-- ----------------------------------------------------------------------------

instance KnownFieldSchema Text where
  fieldToSchema _ = SchemaString Nothing

instance KnownFieldSchema Int where
  fieldToSchema _ = SchemaInteger Nothing Nothing

instance KnownFieldSchema Int64 where
  fieldToSchema _ = SchemaInteger Nothing Nothing

instance KnownFieldSchema Double where
  fieldToSchema _ = SchemaNumber

instance KnownFieldSchema Bool where
  fieldToSchema _ = SchemaBoolean

instance (KnownFieldSchema a) => KnownFieldSchema [a] where
  fieldToSchema _ = SchemaArray (fieldToSchema (Proxy @a))

instance (KnownFieldSchema a) => KnownFieldSchema (Maybe a) where
  fieldToSchema _ = fieldToSchema (Proxy @a)
  isFieldOptional _ = True

instance (KnownFieldSchema a) => KnownFieldSchema (TriState a) where
  fieldToSchema _ = fieldToSchema (Proxy @a)
  isFieldOptional _ = True

-- ----------------------------------------------------------------------------
-- JSON Schema Serialization (for MCP tools/list and schema export)
-- ----------------------------------------------------------------------------

-- | Convert a 'SchemaNode' to valid JSON Schema bytes.
schemaNodeToJson :: SchemaNode -> ByteString
schemaNodeToJson node = case node of
  SchemaAnnotated mDoc inner ->
    let innerBytes = schemaNodeToJson inner
    in case mDoc of
      Nothing -> innerBytes
      Just doc ->
        if "{" `BS.isPrefixOf` innerBytes && "}" `BS.isSuffixOf` innerBytes
          then
            let stripped = BS.init (BS.tail innerBytes)
                docField = "\"description\":\"" <> escapeJson (TE.encodeUtf8 doc) <> "\""
            in if BS.null stripped
                 then "{" <> docField <> "}"
                 else "{" <> docField <> "," <> stripped <> "}"
          else "{\"description\":\"" <> escapeJson (TE.encodeUtf8 doc) <> "\"}"

  SchemaObject props requiredFields ->
    let propPairs =
          [ "\"" <> escapeJson (TE.encodeUtf8 k) <> "\":" <> schemaNodeToJson v
          | (k, v) <- Map.toList props
          ]
        propsObj = "{" <> BS.intercalate "," propPairs <> "}"
        reqArr = "[" <> BS.intercalate "," [ "\"" <> escapeJson (TE.encodeUtf8 r) <> "\"" | r <- requiredFields ] <> "]"
    in "{\"properties\":" <> propsObj <> ",\"required\":" <> reqArr <> ",\"type\":\"object\"}"

  SchemaString mFmt ->
    case mFmt of
      Nothing  -> "{\"type\":\"string\"}"
      Just fmt -> "{\"format\":\"" <> escapeJson (TE.encodeUtf8 fmt) <> "\",\"type\":\"string\"}"

  SchemaInteger mMin mMax ->
    let parts = catMaybes
          [ Just "\"type\":\"integer\""
          , (\mn -> "\"minimum\":" <> BSC.pack (show mn)) <$> mMin
          , (\mx -> "\"maximum\":" <> BSC.pack (show mx)) <$> mMax
          ]
    in "{" <> BS.intercalate "," parts <> "}"

  SchemaNumber -> "{\"type\":\"number\"}"

  SchemaBoolean -> "{\"type\":\"boolean\"}"

  SchemaArray inner ->
    "{\"items\":" <> schemaNodeToJson inner <> ",\"type\":\"array\"}"

  SchemaRef ref ->
    "{\"$ref\":\"" <> escapeJson (TE.encodeUtf8 ref) <> "\"}"

escapeJson :: ByteString -> ByteString
escapeJson bs = BSC.concatMap esc bs
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = BSC.singleton c

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Hashigakari.Core.Column
-- Description : Column descriptors, SQL data types, and value marshalling
--
-- Column representations and domain tags for extensible record schemas
-- per HASHIGAKARI_DESIGN.md §3.1.
--
-- === Intellectual Lineage & Attribution
-- This module synthesizes database column and value principles pioneered by:
-- * 'beam' (Travis Whitaker) — typed column descriptors (see LICENSES/NOTICE-beam.txt)
-- * 'hasql' (Nikita Volkov) — applicative value codecs
-- * 'large-anon' (Edsko de Vries / Well-Typed) — extensible row dictionaries
-- See @NOTICE.md@ at the repository root.
module Hashigakari.Core.Column
  ( -- * SQL Primitives & Values
    SqlType (..)
  , SqlValue (..)
  , Column (..)
  , Col (..)
    -- * Value Marshalling Classes
  , ToSqlValue (..)
  , FromSqlValue (..)
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Canonical SQL primitive types recognized across Hashigakari dialects.
data SqlType
  = SqlTypeInt4
  | SqlTypeInt8
  | SqlTypeText
  | SqlTypeBool
  | SqlTypeDouble
  | SqlTypeBlob
  | SqlTypeJsonb
  | SqlTypeNullable !SqlType
  deriving stock (Eq, Show, Ord)

-- | Primitive SQL value carrier across dialect compilers and execution engines.
data SqlValue
  = SqlValInt !Int64
  | SqlValText !Text
  | SqlValBool !Bool
  | SqlValDouble !Double
  | SqlValBlob !ByteString
  | SqlValNull
  deriving stock (Eq, Show, Ord)

-- | HKD column descriptor for extensible record schemas.
data Column (f :: Type -> Type) a = Column
  { colFieldName :: !Text
  , colSqlType   :: !SqlType
  } deriving stock (Eq, Show)

-- | Type-level column tag wrapper.
newtype Col a = Col { unCol :: Text }
  deriving stock (Eq, Show)

-- | Class for encoding Haskell domain types into primitive 'SqlValue'.
class ToSqlValue a where
  toSqlValue :: a -> SqlValue

instance ToSqlValue Int64 where
  toSqlValue = SqlValInt

instance ToSqlValue Int where
  toSqlValue = SqlValInt . fromIntegral

instance ToSqlValue Text where
  toSqlValue = SqlValText

instance ToSqlValue Bool where
  toSqlValue = SqlValBool

instance ToSqlValue Double where
  toSqlValue = SqlValDouble

instance ToSqlValue ByteString where
  toSqlValue = SqlValBlob

instance ToSqlValue a => ToSqlValue (Maybe a) where
  toSqlValue Nothing  = SqlValNull
  toSqlValue (Just x) = toSqlValue x

-- | Class for decoding primitive 'SqlValue' into Haskell domain types.
class FromSqlValue a where
  fromSqlValue :: SqlValue -> Either Text a

instance FromSqlValue Int64 where
  fromSqlValue (SqlValInt n) = Right n
  fromSqlValue other         = Left ("Expected SqlValInt, got: " <> T.pack (show other))

instance FromSqlValue Int where
  fromSqlValue (SqlValInt n) = Right (fromIntegral n)
  fromSqlValue other         = Left ("Expected SqlValInt for Int, got: " <> T.pack (show other))

instance FromSqlValue Text where
  fromSqlValue (SqlValText t) = Right t
  fromSqlValue (SqlValBlob b) = Right (TE.decodeUtf8Lenient b)
  fromSqlValue other          = Left ("Expected SqlValText, got: " <> T.pack (show other))

instance FromSqlValue Bool where
  fromSqlValue (SqlValBool b) = Right b
  fromSqlValue (SqlValInt n)  = Right (n /= 0)
  fromSqlValue other          = Left ("Expected SqlValBool, got: " <> T.pack (show other))

instance FromSqlValue Double where
  fromSqlValue (SqlValDouble d) = Right d
  fromSqlValue (SqlValInt n)    = Right (fromIntegral n)
  fromSqlValue other            = Left ("Expected SqlValDouble, got: " <> T.pack (show other))

instance FromSqlValue ByteString where
  fromSqlValue (SqlValBlob b) = Right b
  fromSqlValue (SqlValText t) = Right (TE.encodeUtf8 t)
  fromSqlValue other          = Left ("Expected SqlValBlob, got: " <> T.pack (show other))

instance FromSqlValue a => FromSqlValue (Maybe a) where
  fromSqlValue SqlValNull = Right Nothing
  fromSqlValue val        = Just <$> fromSqlValue val

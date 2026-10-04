{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Format.Dhall.Types
-- Description : Value model, typeclasses, and errors for the Dhall bridge
--
-- Typed representation of Dhall values and value marshalling typeclasses
-- per HASHIGAKARI_DESIGN.md and DECISION-004.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'dhall' (Gabriel Gonzalez) — Dhall normalization and value types
-- * 'large-anon' (Edsko de Vries / Well-Typed) — extensible record rows
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Format.Dhall.Types
  ( -- * Value Model
    DhallValue (..)
    -- * Error Hierarchy
  , DhallError (..)
    -- * Marshalling Typeclasses
  , ToDhallValue (..)
  , FromDhallValue (..)
  ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric.Natural (Natural)

import Kogaki.Core.String (LogicalString, fromText, toText)

-- | Normalized Dhall value AST for configuration records.
data DhallValue
  = DhallText !Text
  | DhallNatural !Natural
  | DhallInteger !Integer
  | DhallDouble !Double
  | DhallBool !Bool
  | DhallList ![DhallValue]
  | DhallOptional !(Maybe DhallValue)
  | DhallRecord !(Map Text DhallValue)
  deriving stock (Eq, Show)

-- | Structured error hierarchy for the Dhall bridge.
data DhallError
  = DhallParseError !Text
  | DhallTypeError !Text
  | DhallMissingField !Text
  | DhallUnknownField !Text
  deriving stock (Eq, Show)

instance Exception DhallError

-- | Class for encoding Haskell domain types into 'DhallValue'.
class ToDhallValue a where
  toDhallValue :: a -> DhallValue

instance ToDhallValue Text where
  toDhallValue = DhallText

instance ToDhallValue LogicalString where
  toDhallValue = DhallText . toText

instance ToDhallValue ByteString where
  toDhallValue = DhallText . TE.decodeUtf8Lenient

instance ToDhallValue Natural where
  toDhallValue = DhallNatural

instance ToDhallValue Integer where
  toDhallValue = DhallInteger

instance ToDhallValue Int64 where
  toDhallValue = DhallInteger . fromIntegral

instance ToDhallValue Int where
  toDhallValue = DhallInteger . fromIntegral

instance ToDhallValue Double where
  toDhallValue = DhallDouble

instance ToDhallValue Bool where
  toDhallValue = DhallBool

instance ToDhallValue a => ToDhallValue (Maybe a) where
  toDhallValue Nothing  = DhallOptional Nothing
  toDhallValue (Just x) = DhallOptional (Just (toDhallValue x))

instance ToDhallValue a => ToDhallValue [a] where
  toDhallValue xs = DhallList (map toDhallValue xs)

-- | Class for decoding 'DhallValue' into Haskell domain types.
class FromDhallValue a where
  fromDhallValue :: DhallValue -> Either DhallError a

instance FromDhallValue Text where
  fromDhallValue (DhallText t) = Right t
  fromDhallValue other        = Left (DhallTypeError ("Expected DhallText, got: " <> T.pack (show other)))

instance FromDhallValue LogicalString where
  fromDhallValue (DhallText t) = Right (fromText t)
  fromDhallValue other        = Left (DhallTypeError ("Expected DhallText for LogicalString, got: " <> T.pack (show other)))

instance FromDhallValue ByteString where
  fromDhallValue (DhallText t) = Right (TE.encodeUtf8 t)
  fromDhallValue other        = Left (DhallTypeError ("Expected DhallText for ByteString, got: " <> T.pack (show other)))

instance FromDhallValue Natural where
  fromDhallValue (DhallNatural n) = Right n
  fromDhallValue (DhallInteger n) | n >= 0 = Right (fromInteger n)
  fromDhallValue other           = Left (DhallTypeError ("Expected DhallNatural, got: " <> T.pack (show other)))

instance FromDhallValue Integer where
  fromDhallValue (DhallInteger n) = Right n
  fromDhallValue (DhallNatural n) = Right (toInteger n)
  fromDhallValue other           = Left (DhallTypeError ("Expected DhallInteger, got: " <> T.pack (show other)))

instance FromDhallValue Int64 where
  fromDhallValue (DhallInteger n) = Right (fromIntegral n)
  fromDhallValue (DhallNatural n) = Right (fromIntegral n)
  fromDhallValue other           = Left (DhallTypeError ("Expected integer for Int64, got: " <> T.pack (show other)))

instance FromDhallValue Int where
  fromDhallValue (DhallInteger n) = Right (fromIntegral n)
  fromDhallValue (DhallNatural n) = Right (fromIntegral n)
  fromDhallValue other           = Left (DhallTypeError ("Expected integer for Int, got: " <> T.pack (show other)))

instance FromDhallValue Double where
  fromDhallValue (DhallDouble d)  = Right d
  fromDhallValue (DhallNatural n) = Right (fromIntegral n)
  fromDhallValue (DhallInteger n) = Right (fromIntegral n)
  fromDhallValue other           = Left (DhallTypeError ("Expected DhallDouble, got: " <> T.pack (show other)))

instance FromDhallValue Bool where
  fromDhallValue (DhallBool b) = Right b
  fromDhallValue other        = Left (DhallTypeError ("Expected DhallBool, got: " <> T.pack (show other)))

instance FromDhallValue a => FromDhallValue (Maybe a) where
  fromDhallValue (DhallOptional Nothing)  = Right Nothing
  fromDhallValue (DhallOptional (Just x)) = Just <$> fromDhallValue x
  fromDhallValue other                    = Just <$> fromDhallValue other

instance FromDhallValue a => FromDhallValue [a] where
  fromDhallValue (DhallList xs) = traverse fromDhallValue xs
  fromDhallValue other          = Left (DhallTypeError ("Expected DhallList, got: " <> T.pack (show other)))

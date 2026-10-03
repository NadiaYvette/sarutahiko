{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Kogaki.Core.String
-- Description : Structured LogicalString and safe UTF-8 boundary conversions
--
-- Implements the 'LogicalString' abstraction per KOGAKI_DESIGN.md §3 and the
-- i18n architectural guidelines. Replaces naked 'ByteString' and untyped
-- 'String' in domain layers with a validated UTF-8 text representation,
-- guaranteeing that conversions to and from wire bytes happen only through
-- total, typed boundary functions.
module Kogaki.Core.String
  ( -- * Core Logical String
    LogicalString (..)
  , UnicodeException (..)

    -- * UTF-8 Boundary Conversions
  , fromByteString
  , fromByteStringLenient
  , toByteString
  , fromText
  , toText
  ) where

import Data.ByteString (ByteString)
import Data.MonoTraversable
  ( Element
  , GrowingAppend
  , MonoFoldable
  , MonoFunctor
  , MonoPointed
  , MonoTraversable (..)
  )
import Data.NonNull (NonNull, fromNullable)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (UnicodeException (..))
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)

-- | Structured Unicode text type for domain and presentation layers.
--
-- Guaranteed to contain well-formed Unicode text. In wire protocols,
-- 'LogicalString' is converted to and from 'ByteString' exclusively at
-- the boundary via 'toByteString' and 'fromByteString'.
--
-- @since 0.1.0.0
newtype LogicalString = LogicalString
  { getLogical :: Text
  } deriving stock (Generic)
    deriving newtype
      ( Eq
      , Ord
      , Show
      , Read
      , IsString
      , Semigroup
      , Monoid
      , MonoFunctor
      , MonoFoldable
      , MonoPointed
      , GrowingAppend
      )

type instance Element LogicalString = Char

instance MonoTraversable LogicalString where
  otraverse f (LogicalString t) = LogicalString <$> otraverse f t
  omapM f (LogicalString t) = LogicalString <$> omapM f t

instance IsString (NonNull LogicalString) where
  fromString s = case fromNullable (fromString s) of
    Nothing -> error "IsString (NonNull LogicalString): empty string"
    Just nn -> nn

-- | Decode a raw UTF-8 byte stream into a 'LogicalString', returning a typed
-- 'UnicodeException' if the input contains malformed or truncated byte sequences.
--
-- @since 0.1.0.0
fromByteString :: ByteString -> Either UnicodeException LogicalString
fromByteString bs = LogicalString <$> TE.decodeUtf8' bs

-- | Decode a raw UTF-8 byte stream into a 'LogicalString', substituting
-- invalid byte sequences with the Unicode replacement character (U+FFFD).
--
-- @since 0.1.0.0
fromByteStringLenient :: ByteString -> LogicalString
fromByteStringLenient bs = LogicalString (TE.decodeUtf8With TEE.lenientDecode bs)

-- | Encode a 'LogicalString' into a canonical UTF-8 byte stream.
--
-- @since 0.1.0.0
toByteString :: LogicalString -> ByteString
toByteString (LogicalString t) = TE.encodeUtf8 t

-- | Lift a 'Text' value into a 'LogicalString'.
--
-- @since 0.1.0.0
fromText :: Text -> LogicalString
fromText = LogicalString

-- | Extract the underlying 'Text' from a 'LogicalString'.
--
-- @since 0.1.0.0
toText :: LogicalString -> Text
toText = getLogical

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.Fields.Witness
-- Description : Value-level and type-level witnesses for field declarations
--
-- Exposes strongly typed field witnesses connecting compile-time Symbols
-- to runtime 'FieldDatum' metadata per FIELDS_RECORDS_DESIGN.md §3.3.
module Sarutahiko.Fields.Witness
  ( -- * Typed Witness
    FieldWitness (..)
  , mkFieldWitness
  , witnessSymbol
  , witnessVersion
  ) where

import Data.Kind (Type)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.TypeLits (KnownSymbol, Symbol)

import Sarutahiko.Fields.Datum
  ( FieldDatum (..)
  , FieldValidationError
  , SchemaVersion
  , fieldSymbolText
  , mkFieldDatum
  , ForOlder
  , Deprecation
  )

-- | A typed witness tying together a type-level 'Symbol', the target value 'Type',
-- and its registered 'FieldDatum' metadata.
newtype FieldWitness (s :: Symbol) (a :: Type) = FieldWitness
  { unFieldWitness :: FieldDatum s a
  }

instance Show (FieldWitness s a) where
  show (FieldWitness fd) = "FieldWitness (" ++ show fd ++ ")"

-- | Smart constructor for creating a validated 'FieldWitness'.
mkFieldWitness
  :: forall s a. Proxy s
  -> SchemaVersion
  -> Maybe Deprecation
  -> ForOlder a
  -> Either FieldValidationError (FieldWitness s a)
mkFieldWitness p ver mDep forOlder =
  FieldWitness <$> mkFieldDatum p ver mDep forOlder

-- | Get the symbol name of a witness as text.
witnessSymbol :: forall s a. KnownSymbol s => FieldWitness s a -> Text
witnessSymbol (FieldWitness fd) = fieldSymbolText fd

-- | Get the introduction version of a witness.
witnessVersion :: FieldWitness s a -> SchemaVersion
witnessVersion (FieldWitness fd) = fdIntroVer fd

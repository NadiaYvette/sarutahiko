{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.Fields.Registry
-- Description : Field registry satisfying contracts CD1–CD2
--
-- Provides a domain-scoped registry ensuring that every field symbol is
-- declared once (CD2) and satisfies version monotonicity and total
-- upgrade provisions (CD1) per FIELDS_RECORDS_DESIGN.md §3.
module Sarutahiko.Fields.Registry
  ( -- * Dynamic Field Packaging
    SomeField (..)
  , someFieldSymbol
  , someFieldVersion

    -- * Registry Types
  , FieldRegistry (..)
  , RegistryError (..)

    -- * Registry Combinators
  , emptyRegistry
  , registerField
  , registerFieldDatum
  , registerFields
  , lookupField
  , registrySize
  , allFields
  ) where

import Data.Data (TypeRep, Typeable, typeOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import GHC.TypeLits (KnownSymbol)

import Sarutahiko.Fields.Datum
  ( FieldDatum (..)
  , FieldValidationError
  , SchemaVersion
  , fieldSymbolText
  , validateFieldDatum
  )

-- | Existential packaging for a typed 'FieldDatum' with dynamic introspection capabilities.
data SomeField where
  SomeField
    :: forall s a. (KnownSymbol s, Typeable a)
    => !(FieldDatum s a)
    -> SomeField

instance Show SomeField where
  show (SomeField fd) = "SomeField @" ++ show (fieldSymbolText fd) ++ " (" ++ show fd ++ ")"

-- | Extract the symbol name from 'SomeField'.
someFieldSymbol :: SomeField -> Text
someFieldSymbol (SomeField fd) = fieldSymbolText fd

-- | Extract the schema introduction version from 'SomeField'.
someFieldVersion :: SomeField -> SchemaVersion
someFieldVersion (SomeField fd) = fdIntroVer fd

-- | Extract the 'TypeRep' of the field value.
someFieldTypeRep :: SomeField -> TypeRep
someFieldTypeRep (SomeField (_ :: FieldDatum s a)) = typeOf (undefined :: a)

-- | Errors encountered during field registration and validation.
data RegistryError
  = DuplicateFieldSymbol !Text !TypeRep !TypeRep
    -- ^ CD2 violation: Attempted to declare the same field symbol with different type representations.
  | ConflictingFieldVersion !Text !SchemaVersion !SchemaVersion
    -- ^ CD2 violation: Attempted to re-declare the same field symbol with a different introduction version.
  | InvalidFieldMetadata !Text !FieldValidationError
    -- ^ CD1 violation: Field fails required metadata checks.
  deriving stock (Eq, Show)

-- | A validated field registry mapping symbol names to their unique, canonical definitions.
newtype FieldRegistry = FieldRegistry
  { unFieldRegistry :: Map Text SomeField
  } deriving stock (Show)

-- | An empty field registry.
emptyRegistry :: FieldRegistry
emptyRegistry = FieldRegistry Map.empty

-- | Register a dynamic 'SomeField' into the registry, validating CD1 and CD2.
registerField :: SomeField -> FieldRegistry -> Either RegistryError FieldRegistry
registerField sf@(SomeField fd) (FieldRegistry reg) = do
  let sym = fieldSymbolText fd
  -- CD1: Validate metadata
  case validateFieldDatum fd of
    Left err -> Left (InvalidFieldMetadata sym err)
    Right () ->
      -- CD2: Check for collisions
      case Map.lookup sym reg of
        Nothing ->
          Right (FieldRegistry (Map.insert sym sf reg))
        Just existing ->
          let existingType = someFieldTypeRep existing
              newType = someFieldTypeRep sf
              existingVer = someFieldVersion existing
              newVer = fdIntroVer fd
          in if existingType /= newType
               then Left (DuplicateFieldSymbol sym existingType newType)
               else if existingVer /= newVer
                 then Left (ConflictingFieldVersion sym existingVer newVer)
                 else Right (FieldRegistry reg) -- Idempotent re-declaration of identical field

-- | Register a strongly typed 'FieldDatum' into the registry.
registerFieldDatum
  :: (KnownSymbol s, Typeable a)
  => FieldDatum s a
  -> FieldRegistry
  -> Either RegistryError FieldRegistry
registerFieldDatum fd = registerField (SomeField fd)

-- | Register a batch of fields sequentially.
registerFields :: [SomeField] -> Either RegistryError FieldRegistry
registerFields = foldl (\acc sf -> acc >>= registerField sf) (Right emptyRegistry)

-- | Look up a field definition by its symbol text.
lookupField :: Text -> FieldRegistry -> Maybe SomeField
lookupField sym (FieldRegistry reg) = Map.lookup sym reg

-- | Total count of registered fields.
registrySize :: FieldRegistry -> Int
registrySize (FieldRegistry reg) = Map.size reg

-- | Return all registered fields in the registry.
allFields :: FieldRegistry -> [SomeField]
allFields (FieldRegistry reg) = Map.elems reg

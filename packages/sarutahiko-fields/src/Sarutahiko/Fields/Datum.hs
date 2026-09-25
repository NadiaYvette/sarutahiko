{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Sarutahiko.Fields.Datum
-- Description : First-class field datums satisfying contracts CD1–CD2
--
-- Anchors typed field metadata (monotonic introduction versions, two-phase
-- deprecation schedules, and total upgrade provisions for older schemas)
-- directly in first-class Haskell values per FIELDS_RECORDS_DESIGN.md §3.
module Sarutahiko.Fields.Datum
  ( -- * Schema Version
    SchemaVersion (..)
  , initialSchemaVersion

    -- * Deprecation Metadata
  , Deprecation (..)

    -- * Upgrade Provision (E2 / CD1)
  , ForOlder (..)
  , isTotalForOlder

    -- * First-Class Field Datum (CD1 / CD2)
  , FieldDatum (..)
  , mkFieldDatum
  , fieldSymbolText

    -- * Validation & Errors
  , FieldValidationError (..)
  , validateFieldDatum
  ) where

import Data.Data (Data)
import Data.Dynamic (Dynamic)
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)

-- | Monotonic schema version for field lineage tracking (CD1).
newtype SchemaVersion = SchemaVersion
  { unSchemaVersion :: Word32
  } deriving stock (Eq, Ord, Show, Read, Data)

-- | The foundational schema version (v1).
initialSchemaVersion :: SchemaVersion
initialSchemaVersion = SchemaVersion 1

-- | Deprecation tracking for two-phase field retirement (CD1, E5).
data Deprecation = Deprecated
  { depSince   :: !SchemaVersion  -- ^ Schema version where field became deprecated
  , depMessage :: !Text           -- ^ Migration or sunset notice
  , depDropAt  :: !SchemaVersion  -- ^ Planned schema version where field is removed
  } deriving stock (Eq, Show, Data)

-- | Total upgrade provision for older payloads when deserialized under newer schemas (CD1, E2).
--
-- A field introduced at 'initialSchemaVersion' (v1) carries 'NoDefault' because it
-- is present in the initial schema. Every field added in later versions (> v1) MUST
-- provide a total upgrade fallback ('StaticDefault' or 'DerivedDefault').
data ForOlder a
  = NoDefault
    -- ^ Valid only for fields introduced at v1 ('initialSchemaVersion').
  | StaticDefault !a
    -- ^ Deterministic constant fallback.
  | DerivedDefault !(Dynamic -> Maybe a)
    -- ^ Dynamic derivation from existing fields or environment.
  | CustomDefault !(Text -> Either Text a)
    -- ^ Custom deserialization/migration parser.

instance Show a => Show (ForOlder a) where
  show NoDefault = "NoDefault"
  show (StaticDefault a) = "StaticDefault (" ++ show a ++ ")"
  show (DerivedDefault _) = "DerivedDefault <function>"
  show (CustomDefault _) = "CustomDefault <function>"

-- | A field introduced after v1 must provide a valid upgrade fallback provision.
isTotalForOlder :: SchemaVersion -> ForOlder a -> Bool
isTotalForOlder ver provision
  | ver <= initialSchemaVersion = True
  | otherwise = case provision of
      NoDefault -> False
      StaticDefault _ -> True
      DerivedDefault _ -> True
      CustomDefault _ -> True

-- | First-class typed field datum representing a known schema key (CD1).
data FieldDatum (s :: Symbol) (a :: Type) = FieldDatum
  { fdSymbol      :: !(Proxy s)
  , fdIntroVer    :: !SchemaVersion
  , fdDeprecation :: !(Maybe Deprecation)
  , fdForOlder    :: !(ForOlder a)
  }

instance Show (FieldDatum s a) where
  show fd = "FieldDatum { fdIntroVer = " ++ show (fdIntroVer fd)
         ++ ", fdDeprecation = " ++ show (fdDeprecation fd)
         ++ " }"

-- | Returns the symbol text for a known symbol field datum.
fieldSymbolText :: forall s a. KnownSymbol s => FieldDatum s a -> Text
fieldSymbolText _ = T.pack (symbolVal (Proxy :: Proxy s))

-- | Possible validation failures violating CD1/CD2 contracts.
data FieldValidationError
  = ZeroSchemaVersion
    -- ^ Schema versions must be >= 1.
  | MissingForOlderProvision !SchemaVersion
    -- ^ Fields introduced at version > 1 must provide a fallback for older schemas.
  | InvalidDeprecationSchedule !SchemaVersion !SchemaVersion
    -- ^ 'depSince' must be <= 'depDropAt' and >= 'fdIntroVer'.
  deriving stock (Eq, Show, Data)

-- | Validate that a 'FieldDatum' satisfies all CD1 metadata invariants.
validateFieldDatum :: forall s a. FieldDatum s a -> Either FieldValidationError ()
validateFieldDatum fd = do
  let intro = fdIntroVer fd
  if intro < initialSchemaVersion
    then Left ZeroSchemaVersion
    else do
      if not (isTotalForOlder intro (fdForOlder fd))
        then Left (MissingForOlderProvision intro)
        else case fdDeprecation fd of
          Nothing -> Right ()
          Just dep ->
            if depSince dep < intro || depDropAt dep < depSince dep
              then Left (InvalidDeprecationSchedule (depSince dep) (depDropAt dep))
              else Right ()

-- | Smart constructor constructing and validating a 'FieldDatum'.
mkFieldDatum
  :: forall s a. Proxy s
  -> SchemaVersion
  -> Maybe Deprecation
  -> ForOlder a
  -> Either FieldValidationError (FieldDatum s a)
mkFieldDatum p intro mDep forOlder =
  let fd = FieldDatum p intro mDep forOlder
  in case validateFieldDatum fd of
       Left err -> Left err
       Right () -> Right fd

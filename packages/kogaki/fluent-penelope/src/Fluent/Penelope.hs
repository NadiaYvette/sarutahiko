{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | Module: Fluent.Penelope
-- Description: Localize and MultiLocale effect signatures over Penelope and Kogaki
--
-- Exposes typed 'Localize' and 'MultiLocale' effect carriers parameterised over
-- closed @polytropos@ 'SumRow' catalogs, interoperating with 'Kogaki.Ontology'
-- ('Tier', 'LocaleTag', 'RichText', 'SemanticTag').
module Fluent.Penelope
  ( -- * Effect Signatures
    Localize(..)
  , MultiLocale(..)
    -- * Runtime Localization Environment
  , LocalizationEnv(..)
  , emptyLocalizationEnv
  , addCatalog
    -- * Pure Interpretation
  , runLocalizePure
  ) where

import Data.Kind (Type)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Fluent.Polytropos.Schema (CatalogSchema (..))
import Kogaki.Ontology
  ( LocaleTag (..)
  , RichText (..)
  , SemanticTag (..)
  , Tier (..)
  )
import Polytropos (SumRow, Variant)

-- | First-order localization effect parameterized over catalog @cat@.
data Localize (cat :: SumRow) :: Type -> Type where
  -- | Resolves and formats a message variant into structured 'RichText'.
  LocalizeMessage :: Variant cat -> Localize cat (RichText SemanticTag)
  -- | Queries the active locale tag.
  GetActiveLocale :: Localize cat LocaleTag
  -- | Queries the reliability tier of the active catalog.
  GetActiveTier   :: Localize cat Tier

-- | Scoped multi-locale effect for switching or querying fallback cascades.
data MultiLocale (cat :: SumRow) :: Type -> Type where
  -- | Temporarily sets the active locale during computation.
  WithLocale    :: LocaleTag -> m a -> MultiLocale cat (m a)
  -- | Inspects available localized catalogs.
  ListLocales   :: MultiLocale cat [LocaleTag]

-- | In-memory localization environment mapping locale tags to catalog metadata.
data LocalizationEnv = LocalizationEnv
  { envCurrentLocale :: !LocaleTag
  , envCurrentTier   :: !Tier
  , envCatalogs      :: !(Map LocaleTag CatalogSchema)
  } deriving stock (Eq, Show)

-- | Empty localization environment defaulting to @en@ and 'Tier0'.
emptyLocalizationEnv :: LocalizationEnv
emptyLocalizationEnv = LocalizationEnv
  { envCurrentLocale = LocaleTag "en"
  , envCurrentTier   = Tier0
  , envCatalogs      = Map.empty
  }

-- | Registers a localized catalog into the environment.
addCatalog :: CatalogSchema -> LocalizationEnv -> LocalizationEnv
addCatalog schema env =
  let tag = LocaleTag (csLocale schema)
  in env { envCatalogs = Map.insert tag schema (envCatalogs env) }

-- | Pure reference evaluator for 'Localize' queries against a known text resolver.
runLocalizePure :: (Variant cat -> RichText SemanticTag) -> Localize cat a -> LocalizationEnv -> (a, LocalizationEnv)
runLocalizePure renderOp (LocalizeMessage msg) env = (renderOp msg, env)
runLocalizePure _ GetActiveLocale env               = (envCurrentLocale env, env)
runLocalizePure _ GetActiveTier env                 = (envCurrentTier env, env)

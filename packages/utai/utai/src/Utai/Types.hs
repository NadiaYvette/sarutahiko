{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Utai.Types
-- Description : Core types, provider profiles, and re-exports for utai
--
-- Re-exports the neutral 'ModelAPI' signature and row types from
-- 'Sarutahiko.Effect.ModelAPI' and provides zero-token local provider profiles
-- matching workspace configuration per LLM_SUBSTRATE_DESIGN.md §6.1.
module Utai.Types
  ( -- * Re-exported Domain Types
    module Sarutahiko.Effect.ModelAPI

    -- * Provider Profiles
  , ProviderProfile (..)
  , omnirouteProfile
  , opencodeProfile
  , kaggleProfile
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

import Sarutahiko.Effect.ModelAPI

-- | Provider profile configuration.
data ProviderProfile = ProviderProfile
  { profileName    :: !Text
  , profileBaseUrl :: !Text
  , profileApiKey  :: !Text
  , profileModels  :: ![Text]
  } deriving stock (Eq, Show, Generic)

-- | OmniRoute dynamic gateway at http://localhost:20128/v1
-- Supports auto-routing and local free fleet.
omnirouteProfile :: ProviderProfile
omnirouteProfile = ProviderProfile
  { profileName    = "omniroute"
  , profileBaseUrl = "http://localhost:20128/v1"
  , profileApiKey  = "sk-nadia-master"
  , profileModels  =
      [ "auto"
      , "auto/best-coding"
      , "auto/best-reasoning"
      , "auto/best-fast"
      , "gemini/gemini-3.8-flash"
      , "nvidia/nvidia/nemotron-3-super-120b-a12b"
      , "mistral/codestral-latest"
      ]
  }

-- | OpenCode standalone local provider at http://127.0.0.1:20129/v1
opencodeProfile :: ProviderProfile
opencodeProfile = ProviderProfile
  { profileName    = "opencode"
  , profileBaseUrl = "http://127.0.0.1:20129/v1"
  , profileApiKey  = "sk-opencode-local"
  , profileModels  =
      [ "opencode/space-bunny-free"
      , "opencode/ling-3.0-flash-fin-free"
      , "opencode/nemotron-3.5-lightning-free"
      ]
  }

-- | Kaggle Cloud GPU gateway at http://127.0.0.1:20130/v1
kaggleProfile :: ProviderProfile
kaggleProfile = ProviderProfile
  { profileName    = "kaggle"
  , profileBaseUrl = "http://127.0.0.1:20130/v1"
  , profileApiKey  = "sk-kaggle-local"
  , profileModels  =
      [ "gemma4:A12B"
      ]
  }

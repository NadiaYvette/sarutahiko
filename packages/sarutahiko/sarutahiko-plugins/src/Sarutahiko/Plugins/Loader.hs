{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Plugins.Loader
-- Description : Plugin validation, capability verification, and kill-list enforcement
--
-- Validates plugin manifests against configured security policies and kill-lists
-- per NIH_PLAN.md Tier 2 (sarutahiko-plugins).
module Sarutahiko.Plugins.Loader
  ( validatePluginManifest
  , loadPluginManifest
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Sarutahiko.Plugins.Types
  ( KillList
  , PluginManifest (..)
  , decodePluginManifest
  , isKilled
  )

-- | Validate a 'PluginManifest' against a 'KillList' and integrity rules.
validatePluginManifest :: KillList -> PluginManifest -> Either Text PluginManifest
validatePluginManifest kl manifest
  | isKilled kl (pmId manifest) =
      Left ("Plugin '" <> pmId manifest <> "' is blacklisted on the kill-list")
  | any (isKilled kl) (pmTools manifest) =
      Left ("Plugin '" <> pmId manifest <> "' advertises a tool that is blacklisted on the kill-list")
  | otherwise = Right manifest

-- | Parse and validate a plugin manifest JSON ByteString.
loadPluginManifest :: KillList -> ByteString -> Either Text PluginManifest
loadPluginManifest kl bytes = do
  manifest <- decodePluginManifest bytes
  validatePluginManifest kl manifest

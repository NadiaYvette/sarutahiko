{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Hooks.Allowlist
-- Description : In-memory and persistent command consent allowlists
--
-- Governs safe mode and user consent requirements for tool and command
-- executions per NIH_PLAN.md Tier 2 (sarutahiko-hooks).
module Sarutahiko.Hooks.Allowlist
  ( -- * Allowlist Type & Construction
    Allowlist (..)
  , emptyAllowlist
  , defaultAllowlist
  , addApprovedTool
  , addApprovedPrefix

    -- * Consent Checking
  , checkToolConsent
  , isCommandAllowed
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import Sarutahiko.Hooks.Types (HookConsent (..))

-- | Configured set of pre-approved tools and command prefixes.
data Allowlist = Allowlist
  { alApprovedTools    :: !(Set Text)
  , alApprovedPrefixes :: ![Text]
  , alSafeMode         :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | An empty allowlist with safe mode enabled.
emptyAllowlist :: Allowlist
emptyAllowlist = Allowlist Set.empty [] True

-- | Default allowlist permitting read-only inspection commands.
defaultAllowlist :: Allowlist
defaultAllowlist = Allowlist
  { alApprovedTools    = Set.fromList ["echo", "read_file", "list_dir", "view_file"]
  , alApprovedPrefixes = ["git status", "git log", "git diff", "ls", "pwd", "cat"]
  , alSafeMode         = True
  }

-- | Add an approved tool name.
addApprovedTool :: Text -> Allowlist -> Allowlist
addApprovedTool t al = al { alApprovedTools = Set.insert t (alApprovedTools al) }

-- | Add an approved command prefix.
addApprovedPrefix :: Text -> Allowlist -> Allowlist
addApprovedPrefix p al = al { alApprovedPrefixes = p : alApprovedPrefixes al }

-- | Check whether a tool call is approved by the allowlist.
checkToolConsent :: Allowlist -> Text -> HookConsent
checkToolConsent al toolName
  | Set.member toolName (alApprovedTools al) = ConsentApproved
  | not (alSafeMode al)                      = ConsentApproved
  | otherwise = ConsentDenied ("Tool '" <> toolName <> "' requires user approval under safe mode")

-- | Check whether a shell command is allowed by prefix matching.
isCommandAllowed :: Allowlist -> Text -> Bool
isCommandAllowed al cmd
  | not (alSafeMode al) = True
  | otherwise = any (`T.isPrefixOf` T.strip cmd) (alApprovedPrefixes al)

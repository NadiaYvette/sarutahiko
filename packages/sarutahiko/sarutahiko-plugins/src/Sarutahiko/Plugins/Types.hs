{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Plugins.Types
-- Description : Plugin manifest types, capability grants, and kill-lists
--
-- Governs dynamic plugin capability grants and kill-list enforcement per
-- NIH_PLAN.md Tier 2 (sarutahiko-plugins).
module Sarutahiko.Plugins.Types
  ( -- * Capability Grants & Kill-Lists
    CapabilityGrant (..)
  , KillList (..)
  , emptyKillList
  , isKilled

    -- * Plugin Manifest
  , PluginManifest (..)

    -- * Wire Serialization
  , encodePluginManifest
  , decodePluginManifest
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Kogaki.Wire.Json.Decode (extractObjectFields)
import Kogaki.Wire.Json.Lexer (JsonToken (..), lexJsonEither)

-- | Explicit capabilities granted to a plugin.
data CapabilityGrant
  = GrantNetwork
  | GrantFilesystem
  | GrantSubprocess
  | GrantModelSampling
  deriving stock (Eq, Ord, Show, Generic)

-- | Kill-list containing revoked/prohibited plugin and tool IDs.
newtype KillList = KillList
  { unKillList :: Set Text
  } deriving stock (Eq, Show, Generic)

-- | Empty kill-list.
emptyKillList :: KillList
emptyKillList = KillList Set.empty

-- | Check whether an ID is blacklisted by the kill-list.
isKilled :: KillList -> Text -> Bool
isKilled kl targetId = Set.member targetId (unKillList kl)

-- | Plugin descriptor manifest.
data PluginManifest = PluginManifest
  { pmId           :: !Text
  , pmName         :: !Text
  , pmVersion      :: !Text
  , pmDescription  :: !Text
  , pmTools        :: ![Text]
  , pmCapabilities :: ![CapabilityGrant]
  , pmEnabled      :: !Bool
  } deriving stock (Eq, Show, Generic)

-- ----------------------------------------------------------------------------
-- Safe Zero-Aeson Codecs
-- ----------------------------------------------------------------------------

encodePluginManifest :: PluginManifest -> ByteString
encodePluginManifest pm =
  let encCap GrantNetwork       = "\"network\""
      encCap GrantFilesystem    = "\"filesystem\""
      encCap GrantSubprocess    = "\"subprocess\""
      encCap GrantModelSampling = "\"model_sampling\""
      capsBytes = "[" <> BS.intercalate "," (map encCap (pmCapabilities pm)) <> "]"
      toolsBytes = "[" <> BS.intercalate "," (map (\t -> "\"" <> escapeJson t <> "\"") (pmTools pm)) <> "]"
      enStr = if pmEnabled pm then "true" else "false"
  in "{\"id\":\"" <> escapeJson (pmId pm)
     <> "\",\"name\":\"" <> escapeJson (pmName pm)
     <> "\",\"version\":\"" <> escapeJson (pmVersion pm)
     <> "\",\"description\":\"" <> escapeJson (pmDescription pm)
     <> "\",\"tools\":" <> toolsBytes
     <> ",\"capabilities\":" <> capsBytes
     <> ",\"enabled\":" <> enStr <> "}"

decodePluginManifest :: ByteString -> Either Text PluginManifest
decodePluginManifest bs = do
  toks <- lexJsonEither bs
  fields <- extractObjectFields toks
  idToks   <- maybe (Left "Missing 'id'") Right (Map.lookup "id" fields)
  nameToks <- maybe (Left "Missing 'name'") Right (Map.lookup "name" fields)
  verToks  <- maybe (Left "Missing 'version'") Right (Map.lookup "version" fields)
  idVal    <- extractStringValue idToks
  nameVal  <- extractStringValue nameToks
  verVal   <- extractStringValue verToks
  descVal  <- case Map.lookup "description" fields of
    Just dToks -> case extractStringValue dToks of
      Right s -> Right s
      Left _  -> Right ""
    Nothing -> Right ""
  let enVal = case Map.lookup "enabled" fields of
        Just [TkBool b] -> b
        _               -> True
  -- Extract tools
  toolsList <- case Map.lookup "tools" fields of
    Just (TkArrayOpen : rest) -> Right [ s | TkString s <- rest ]
    _                         -> Right []
  -- Extract capabilities
  capsList <- case Map.lookup "capabilities" fields of
    Just (TkArrayOpen : rest) -> Right [ c | TkString s <- rest, Just c <- [parseCap s] ]
    _                         -> Right []
  Right PluginManifest
    { pmId           = idVal
    , pmName         = nameVal
    , pmVersion      = verVal
    , pmDescription  = descVal
    , pmTools        = toolsList
    , pmCapabilities = capsList
    , pmEnabled      = enVal
    }

parseCap :: Text -> Maybe CapabilityGrant
parseCap "network"        = Just GrantNetwork
parseCap "filesystem"     = Just GrantFilesystem
parseCap "subprocess"     = Just GrantSubprocess
parseCap "model_sampling" = Just GrantModelSampling
parseCap _                = Nothing

extractStringValue :: [JsonToken] -> Either Text Text
extractStringValue [TkString s] = Right s
extractStringValue [TkKey k]    = Right (TE.decodeUtf8 k)
extractStringValue _            = Left "Expected JSON string token"

escapeJson :: Text -> ByteString
escapeJson = TE.encodeUtf8 . T.pack . concatMap esc . T.unpack
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = [c]

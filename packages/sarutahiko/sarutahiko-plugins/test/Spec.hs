{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Set as Set
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Plugins
  ( CapabilityGrant (..)
  , KillList (..)
  , PluginManifest (..)
  , decodePluginManifest
  , emptyKillList
  , encodePluginManifest
  , validatePluginManifest
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Plugins Test Suite"
  [ testProperty "PluginManifest wire codec roundtrips valid manifests" prop_manifest_codec_roundtrip
  , testProperty "Plugin validation permits authorized plugins" prop_plugin_validation_success
  , testProperty "Kill-list rejects blacklisted plugin IDs" prop_kill_list_rejects_plugin
  , testProperty "Kill-list rejects plugins advertising blacklisted tools" prop_kill_list_rejects_tool
  ]

prop_manifest_codec_roundtrip :: Property
prop_manifest_codec_roundtrip = property $ do
  pId <- forAll $ Gen.text (Range.linear 3 15) Gen.alphaNum
  pName <- forAll $ Gen.text (Range.linear 3 20) Gen.alphaNum
  let manifest = PluginManifest
        { pmId           = pId
        , pmName         = pName
        , pmVersion      = "1.0.0"
        , pmDescription  = "Test plugin description"
        , pmTools        = ["test_tool_a", "test_tool_b"]
        , pmCapabilities = [GrantNetwork, GrantFilesystem]
        , pmEnabled      = True
        }
      bytes = encodePluginManifest manifest

  case decodePluginManifest bytes of
    Left err -> do
      annotate (show err)
      failure
    Right decoded -> do
      pmId decoded === pmId manifest
      pmName decoded === pmName manifest
      pmVersion decoded === pmVersion manifest
      pmTools decoded === pmTools manifest
      pmCapabilities decoded === pmCapabilities manifest
      pmEnabled decoded === pmEnabled manifest

prop_plugin_validation_success :: Property
prop_plugin_validation_success = property $ do
  let manifest = PluginManifest
        { pmId           = "safe-plugin"
        , pmName         = "Safe Plugin"
        , pmVersion      = "0.1.0"
        , pmDescription  = "Does safe things"
        , pmTools        = ["echo", "cat"]
        , pmCapabilities = [GrantFilesystem]
        , pmEnabled      = True
        }
  case validatePluginManifest emptyKillList manifest of
    Right m -> pmId m === "safe-plugin"
    Left _  -> failure

prop_kill_list_rejects_plugin :: Property
prop_kill_list_rejects_plugin = property $ do
  let manifest = PluginManifest
        { pmId           = "rogue-plugin"
        , pmName         = "Rogue Plugin"
        , pmVersion      = "0.1.0"
        , pmDescription  = "Dangerous"
        , pmTools        = ["safe_tool"]
        , pmCapabilities = [GrantSubprocess]
        , pmEnabled      = True
        }
      kl = KillList (Set.singleton "rogue-plugin")

  case validatePluginManifest kl manifest of
    Left _  -> success
    Right _ -> failure

prop_kill_list_rejects_tool :: Property
prop_kill_list_rejects_tool = property $ do
  let manifest = PluginManifest
        { pmId           = "semi-safe-plugin"
        , pmName         = "Plugin"
        , pmVersion      = "0.1.0"
        , pmDescription  = "Has rogue tool"
        , pmTools        = ["safe_tool", "banned_tool"]
        , pmCapabilities = [GrantNetwork]
        , pmEnabled      = True
        }
      kl = KillList (Set.singleton "banned_tool")

  case validatePluginManifest kl manifest of
    Left _  -> success
    Right _ -> failure

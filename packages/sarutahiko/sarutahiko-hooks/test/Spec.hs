{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Hooks
  ( Allowlist (..)
  , HookConsent (..)
  , HookContext (..)
  , HookResult (..)
  , HookSpec (..)
  , HookType (..)
  , checkToolConsent
  , defaultAllowlist
  , emptyAllowlist
  , executeHook
  , isCommandAllowed
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Hooks Test Suite"
  [ testProperty "Allowlist tool consent checking adheres to safe mode" prop_allowlist_tool_consent
  , testProperty "Allowlist command prefix checking permits approved commands" prop_allowlist_command_prefix
  , testProperty "Hook supervisor executes clean subprocess and returns output" prop_hook_supervisor_success
  , testProperty "Hook supervisor strictly enforces fail-closed timeout" prop_hook_supervisor_timeout
  ]

prop_allowlist_tool_consent :: Property
prop_allowlist_tool_consent = property $ do
  tool <- forAll $ Gen.element ["echo", "read_file", "list_dir"]
  unapproved <- forAll $ Gen.filter (`notElem` ["echo", "read_file", "list_dir", "view_file"]) $
    Gen.text (Range.linear 4 15) Gen.alphaNum

  checkToolConsent defaultAllowlist tool === ConsentApproved

  case checkToolConsent defaultAllowlist unapproved of
    ConsentDenied _ -> success
    _               -> failure

  -- With safe mode disabled, all tools approved
  let openAl = emptyAllowlist { alSafeMode = False }
  checkToolConsent openAl unapproved === ConsentApproved

prop_allowlist_command_prefix :: Property
prop_allowlist_command_prefix = property $ do
  cmd <- forAll $ Gen.element ["git status -s", "git log -n 5", "ls -la /tmp", "pwd"]
  disallowed <- forAll $ Gen.element ["rm -rf /", "curl http://evil.com", "reboot"]

  assert (isCommandAllowed defaultAllowlist cmd)
  assert (not (isCommandAllowed defaultAllowlist disallowed))

prop_hook_supervisor_success :: Property
prop_hook_supervisor_success = property $ do
  let spec = HookSpec
        { hsType       = PreTurn
        , hsCommand    = "echo"
        , hsArgs       = ["hook_ok"]
        , hsTimeoutSec = 5
        , hsAllowFail  = False
        }
      ctx = HookContext PreTurn Nothing Nothing "sess-test" "test-model"

  res <- liftIO (executeHook spec ctx)
  hrSuccess res === True
  assert ("hook_ok" `isInfixOfText` hrOutput res)

prop_hook_supervisor_timeout :: Property
prop_hook_supervisor_timeout = withTests 5 $ property $ do
  let spec = HookSpec
        { hsType       = PreToolCall
        , hsCommand    = "sleep"
        , hsArgs       = ["5"]
        , hsTimeoutSec = 1 -- 1 second hard timeout
        , hsAllowFail  = False
        }
      ctx = HookContext PreToolCall (Just "sleep") Nothing "sess-test" "test-model"

  res <- liftIO (executeHook spec ctx)
  hrSuccess res === False
  case hrError res of
    Just err -> assert ("timed out" `isInfixOfText` err)
    Nothing  -> failure

isInfixOfText :: T.Text -> T.Text -> Bool
isInfixOfText = T.isInfixOf

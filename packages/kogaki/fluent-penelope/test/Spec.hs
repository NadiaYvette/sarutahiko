{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Fluent.Penelope
  ( LocalizationEnv (..)
  , Localize (..)
  , emptyLocalizationEnv
  , runLocalizePure
  )
import Kogaki.Ontology (LocaleTag (..), RichText (..), SemanticTag (..), Tier (..))
import System.Exit (exitFailure)

assert :: String -> Bool -> IO ()
assert desc True  = putStrLn ("  [PASS] " ++ desc)
assert desc False = do
  putStrLn ("  [FAIL] " ++ desc)
  exitFailure

main :: IO ()
main = do
  putStrLn "=== fluent-penelope Test Suite ==="

  putStrLn "--- Section 1: Pure Localize Effect Queries ---"
  let env0 = emptyLocalizationEnv
  let (loc, env1) = runLocalizePure @'[] (\_ -> Plain "stub") GetActiveLocale env0
  assert "GetActiveLocale returns default en" $
    loc == LocaleTag "en"

  let (tier, _) = runLocalizePure @'[] (\_ -> Plain "stub") GetActiveTier env1
  assert "GetActiveTier returns default Tier0" $
    tier == Tier0

  putStrLn "=== All fluent-penelope tests passed! ==="

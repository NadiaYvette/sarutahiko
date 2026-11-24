{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import Fluent.Polytropos.Schema (CatalogSchema (..))
import Fluent.Polytropos.TH (deriveFluentCatalog)
import System.Exit (exitFailure)

-- Derive catalog from test fixture
deriveFluentCatalog "AppCatalog" "test/fixtures/messages.ftl"

assert :: String -> Bool -> IO ()
assert desc True  = putStrLn ("  [PASS] " ++ desc)
assert desc False = do
  putStrLn ("  [FAIL] " ++ desc)
  exitFailure

main :: IO ()
main = do
  putStrLn "=== fluent-polytropos Test Suite ==="

  putStrLn "--- Section 1: Template Haskell Catalog Synthesis ---"
  assert "Generated witness appCatalogCatalogSchema has locale en" $
    csLocale appCatalogCatalogSchema == "en"

  putStrLn "=== All fluent-polytropos tests passed! ==="

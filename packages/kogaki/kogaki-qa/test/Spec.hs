{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Fluent.Polytropos.Schema (mkEmptyCatalog)
import Kogaki.Locales.Registry (builtinPolicies)
import Kogaki.Ontology
  ( LocalePolicy (..)
  , LocaleTag (..)
  , Provenance (..)
  , Tier (..)
  )
import Kogaki.QA
  ( QAViolation (..)
  , checkNoMT
  , detectRawEscapes
  , validateCatalog
  )
import qualified Data.Map.Strict as Map
import System.Exit (exitFailure)

assert :: String -> Bool -> IO ()
assert desc True  = putStrLn ("  [PASS] " ++ desc)
assert desc False = do
  putStrLn ("  [FAIL] " ++ desc)
  exitFailure

main :: IO ()
main = do
  putStrLn "=== kogaki-qa Test Suite ==="

  putStrLn "--- Section 1: NoMT Provenance Enforcement ---"
  let dsbPolicy = builtinPolicies Map.! LocaleTag "dsb"
  assert "dsb (NoMT) rejects MachineTranslated provenance" $
    case checkNoMT dsbPolicy (MachineTranslated "nllb-200") of
      Just (DisallowedMT (LocaleTag "dsb") "nllb-200") -> True
      _ -> False

  assert "dsb accepts HumanAuthored provenance" $
    case checkNoMT dsbPolicy (HumanAuthored "Native Sorbian Speaker") of
      Nothing -> True
      _       -> False

  let dePolicy = builtinPolicies Map.! LocaleTag "de"
  assert "de allows MachineTranslated provenance" $
    case checkNoMT dePolicy (MachineTranslated "deepl") of
      Nothing -> True
      _       -> False

  putStrLn "--- Section 2: Raw Escape Detection ---"
  let rawAnsi = "hello \ESC[31mred\ESC[0m world\n"
  assert "detectRawEscapes flags ANSI sequence" $
    case detectRawEscapes rawAnsi of
      [RawAnsiEscape 1 _] -> True
      _ -> False

  let rawRoff = ".TH MYPROG 1\nhello\n"
  assert "detectRawEscapes flags roff macro" $
    case detectRawEscapes rawRoff of
      [RawRoffMacro 1 _] -> True
      _ -> False

  let cleanFtl = "msg-welcome = Welcome, { $name }!\n"
  assert "detectRawEscapes passes clean FTL" $
    null (detectRawEscapes cleanFtl)

  putStrLn "--- Section 3: Full Catalog Validation ---"
  let refSchema = mkEmptyCatalog "en"
  let targetSchema = mkEmptyCatalog "dsb"
  let viols = validateCatalog dsbPolicy (HumanAuthored "Nadia") refSchema targetSchema cleanFtl
  assert "validateCatalog passes compliant human-authored dsb catalog" $
    null viols

  putStrLn "=== All kogaki-qa tests passed! ==="

{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Format.Dhall.Render
-- Description : Serialization of Dhall values and record literals
--
-- Pretty-printing of Dhall values into canonical Dhall record syntax
-- per HASHIGAKARI_DESIGN.md and DECISION-004.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'dhall' (Gabriel Gonzalez) — Dhall pretty-printer
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Format.Dhall.Render
  ( renderDhallValue
  , renderDhallRecord
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

import Sarutahiko.Format.Dhall.Types (DhallValue (..))

-- | Render a normalized 'DhallValue' into Dhall syntax text.
renderDhallValue :: DhallValue -> Text
renderDhallValue val = case val of
  DhallText t ->
    "\"" <> escapeString t <> "\""
  DhallNatural n ->
    T.pack (show n)
  DhallInteger n ->
    if n >= 0
      then "+" <> T.pack (show n)
      else T.pack (show n)
  DhallDouble d ->
    T.pack (show d)
  DhallBool b ->
    if b then "True" else "False"
  DhallList xs ->
    "[" <> T.intercalate ", " (map renderDhallValue xs) <> "]"
  DhallOptional Nothing ->
    "None"
  DhallOptional (Just x) ->
    "Some (" <> renderDhallValue x <> ")"
  DhallRecord m ->
    renderDhallRecord m

-- | Render a map of fields into a Dhall record literal '{ field = value, ... }'.
renderDhallRecord :: Map Text DhallValue -> Text
renderDhallRecord m
  | Map.null m = "{}"
  | otherwise  =
      let fields = [ k <> " = " <> renderDhallValue v | (k, v) <- Map.toList m ]
      in "{ " <> T.intercalate ", " fields <> " }"

-- | Escape control characters and quotes in string literals.
escapeString :: Text -> Text
escapeString = T.concatMap $ \case
  '"'  -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\t' -> "\\t"
  '\r' -> "\\r"
  c    -> T.singleton c

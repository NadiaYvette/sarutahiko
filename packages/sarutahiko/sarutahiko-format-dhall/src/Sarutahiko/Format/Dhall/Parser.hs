{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Format.Dhall.Parser
-- Description : Total parser for Dhall record literals
--
-- Pure, total recursive-descent parser for Dhall configuration records
-- per HASHIGAKARI_DESIGN.md and DECISION-004.
--
-- === Intellectual Lineage & Attribution
-- Synthesized from:
-- * 'dhall' (Gabriel Gonzalez) — Dhall syntax specification
-- * 'kogaki-wire' — total zero-partial scanning
-- See @NOTICE.md@ at the repository root.
module Sarutahiko.Format.Dhall.Parser
  ( parseDhallValue
  , parseDhallRecord
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR

import Sarutahiko.Format.Dhall.Types (DhallError (..), DhallValue (..))

-- | Parse a Dhall text source into a normalized 'DhallValue'.
parseDhallValue :: Text -> Either DhallError DhallValue
parseDhallValue input = do
  (val, rest) <- parseExpr (skipSpacesAndComments input)
  let trailing = skipSpacesAndComments rest
  if T.null trailing
    then Right val
    else Left (DhallParseError ("Trailing unparsed characters: " <> T.take 30 trailing))

-- | Parse a Dhall text source specifically into a 'DhallRecord' map.
parseDhallRecord :: Text -> Either DhallError (Map Text DhallValue)
parseDhallRecord input = do
  val <- parseDhallValue input
  case val of
    DhallRecord m -> Right m
    other         -> Left (DhallTypeError ("Expected top-level Dhall record, got: " <> T.pack (show other)))

-- ----------------------------------------------------------------------------
-- Recursive-Descent Expression Parser
-- ----------------------------------------------------------------------------

parseExpr :: Text -> Either DhallError (DhallValue, Text)
parseExpr txt =
  let s = skipSpacesAndComments txt
  in case T.uncons s of
    Nothing -> Left (DhallParseError "Unexpected end of input while parsing expression")
    Just ('{', rest) -> parseRecordLiteral rest
    Just ('[', rest) -> parseListLiteral rest
    Just ('"', rest) -> parseStringLiteral rest
    Just (c, _)
      | c == '-' || c == '+' || isDigit c -> parseNumericLiteral s
      | isAlpha c -> parseIdentifierOrKeyword s
      | otherwise -> Left (DhallParseError ("Unexpected character at start of expression: " <> T.singleton c))

-- | Skip whitespace and '--' line comments.
skipSpacesAndComments :: Text -> Text
skipSpacesAndComments t =
  let s = T.dropWhile isSpace t
  in if "--" `T.isPrefixOf` s
       then skipSpacesAndComments (T.dropWhile (/= '\n') s)
       else s

-- | Parse a record literal '{ field = val, ... }'.
parseRecordLiteral :: Text -> Either DhallError (DhallValue, Text)
parseRecordLiteral input = do
  let s = skipSpacesAndComments input
  case T.uncons s of
    Just ('}', rest) -> Right (DhallRecord Map.empty, rest)
    Just (',', rest) ->
      -- Dhall empty record can be written as '{,}'
      let s2 = skipSpacesAndComments rest
      in case T.uncons s2 of
        Just ('}', r2) -> Right (DhallRecord Map.empty, r2)
        _              -> parseFields s Map.empty
    _ -> parseFields s Map.empty
  where
    parseFields :: Text -> Map Text DhallValue -> Either DhallError (DhallValue, Text)
    parseFields curr acc = do
      let s1 = skipSpacesAndComments curr
      case T.uncons s1 of
        Just ('}', rest) -> Right (DhallRecord acc, rest)
        _ -> do
          (fieldName, s2) <- parseFieldName s1
          let s3 = skipSpacesAndComments s2
          case T.uncons s3 of
            Just ('=', s4) -> do
              (val, s5) <- parseExpr s4
              let acc' = Map.insert fieldName val acc
                  s6 = skipSpacesAndComments s5
              case T.uncons s6 of
                Just (',', s7) -> parseFields s7 acc'
                Just ('}', s7) -> Right (DhallRecord acc', s7)
                _              -> Left (DhallParseError ("Expected ',' or '}' after field " <> fieldName))
            _ -> Left (DhallParseError ("Expected '=' after field name " <> fieldName))

-- | Parse a field name identifier.
parseFieldName :: Text -> Either DhallError (Text, Text)
parseFieldName txt =
  let s = skipSpacesAndComments txt
  in case T.uncons s of
    Nothing -> Left (DhallParseError "Expected field identifier, got end of input")
    Just ('`', rest) ->
      -- Quoted field name
      let (name, r) = T.breakOn "`" rest
      in case T.uncons r of
        Just ('`', rest') -> Right (name, rest')
        _                 -> Left (DhallParseError "Unclosed backtick identifier")
    Just (c, _)
      | isAlpha c || c == '_' ->
        let (ident, rest) = T.span (\x -> isAlphaNum x || x == '_' || x == '-') s
        in Right (ident, rest)
      | otherwise -> Left (DhallParseError ("Invalid character in field name: " <> T.singleton c))

-- | Parse a string literal with escape handling.
parseStringLiteral :: Text -> Either DhallError (DhallValue, Text)
parseStringLiteral input = go input ""
  where
    go curr acc = case T.uncons curr of
      Nothing -> Left (DhallParseError "Unterminated string literal")
      Just ('"', rest) -> Right (DhallText acc, rest)
      Just ('\\', rest) -> case T.uncons rest of
        Just ('"', r)  -> go r (acc `T.snoc` '"')
        Just ('\\', r) -> go r (acc `T.snoc` '\\')
        Just ('n', r)  -> go r (acc `T.snoc` '\n')
        Just ('t', r)  -> go r (acc `T.snoc` '\t')
        Just ('r', r)  -> go r (acc `T.snoc` '\r')
        Just (esc, r)  -> go r (acc `T.snoc` esc)
        Nothing        -> Left (DhallParseError "Unterminated escape in string literal")
      Just (c, rest) -> go rest (acc `T.snoc` c)

-- | Parse numbers: Double, Integer, or Natural.
parseNumericLiteral :: Text -> Either DhallError (DhallValue, Text)
parseNumericLiteral txt =
  let (numStr, rest) = T.span (\c -> isDigit c || c == '.' || c == '+' || c == '-' || c == 'e' || c == 'E') txt
  in if "." `T.isInfixOf` numStr || "e" `T.isInfixOf` numStr || "E" `T.isInfixOf` numStr
       then case TR.double numStr of
         Right (d, "") -> Right (DhallDouble d, rest)
         _             -> Left (DhallParseError ("Failed to parse double: " <> numStr))
       else if "-" `T.isPrefixOf` numStr || "+" `T.isPrefixOf` numStr
         then case TR.signed TR.decimal numStr of
           Right (n, "") -> Right (DhallInteger n, rest)
           _             -> Left (DhallParseError ("Failed to parse integer: " <> numStr))
         else case TR.decimal numStr of
           Right (n, "") -> Right (DhallNatural n, rest)
           _             -> Left (DhallParseError ("Failed to parse natural: " <> numStr))

-- | Parse keywords: True, False, Some, None.
parseIdentifierOrKeyword :: Text -> Either DhallError (DhallValue, Text)
parseIdentifierOrKeyword txt =
  let (ident, rest) = T.span (\c -> isAlphaNum c || c == '_') txt
  in case ident of
    "True"  -> Right (DhallBool True, rest)
    "False" -> Right (DhallBool False, rest)
    "None"  -> Right (DhallOptional Nothing, rest)
    "Some"  -> do
      (inner, rest') <- parseExpr rest
      Right (DhallOptional (Just inner), rest')
    other   -> Left (DhallParseError ("Unknown identifier: " <> other))

-- | Parse list literal '[ x, y, z ]'.
parseListLiteral :: Text -> Either DhallError (DhallValue, Text)
parseListLiteral input = do
  let s = skipSpacesAndComments input
  case T.uncons s of
    Just (']', rest) -> Right (DhallList [], rest)
    _                -> parseItems s []
  where
    parseItems curr acc = do
      (item, s1) <- parseExpr curr
      let s2 = skipSpacesAndComments s1
      case T.uncons s2 of
        Just (',', s3) -> parseItems s3 (acc ++ [item])
        Just (']', s3) -> Right (DhallList (acc ++ [item]), s3)
        _              -> Left (DhallParseError "Expected ',' or ']' in list literal")

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Tags.Extractor
-- Description : Scope-stack tag extraction for Haskell, C, and procedural sources
--
-- Analyzes source lines to extract definitions, types, functions, modules,
-- and macros with line numbers and pattern searches.
module Sarutahiko.Tags.Extractor
  ( extractTagsFromSource
  , extractHaskellTags
  , extractCTags
  ) where

import Data.Char (isAlphaNum)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (takeExtension)

import Sarutahiko.Tags.Types

-- | Dispatch extraction based on file extension.
extractTagsFromSource :: FilePath -> Text -> [TagEntry]
extractTagsFromSource fp content =
  let ext = takeExtension fp
  in case ext of
    ".hs"  -> extractHaskellTags fp content
    ".lhs" -> extractHaskellTags fp content
    ".c"   -> extractCTags fp content
    ".h"   -> extractCTags fp content
    ".cpp" -> extractCTags fp content
    _      -> extractHaskellTags fp content

-- | Extract symbols from a Haskell source file.
extractHaskellTags :: FilePath -> Text -> [TagEntry]
extractHaskellTags fp content =
  let lns = zip [1..] (T.lines content)
  in catMaybes (concatMap (parseHaskellLine fp) lns)

parseHaskellLine :: FilePath -> (Int, Text) -> [Maybe TagEntry]
parseHaskellLine fp (lineNum, rawLine) =
  let line = T.strip rawLine
      pat = "^" <> T.strip rawLine <> "$"
  in if T.null line || "--" `T.isPrefixOf` line
       then []
       else
         let ws = T.words line
         in case ws of
           ("module" : modName : _) ->
             let cleanMod = fst (T.breakOn "(" modName)
             in [Just $ TagEntry cleanMod fp lineNum TagModule pat Nothing]

           ("data" : dName : _) ->
             let cleanName = fst (T.breakOn "=" (fst (T.breakOn " " dName)))
             in [Just $ TagEntry cleanName fp lineNum TagData pat Nothing]

           ("newtype" : nName : _) ->
             let cleanName = fst (T.breakOn "=" (fst (T.breakOn " " nName)))
             in [Just $ TagEntry cleanName fp lineNum TagData pat Nothing]

           ("type" : tName : _) ->
             let cleanName = fst (T.breakOn "=" (fst (T.breakOn " " tName)))
             in [Just $ TagEntry cleanName fp lineNum TagType pat Nothing]

           ("class" : cName : _) ->
             let cleanName = fst (T.breakOn "=>" (fst (T.breakOn " " cName)))
             in [Just $ TagEntry cleanName fp lineNum TagClass pat Nothing]

           _ ->
             -- Check for top-level function signature "name :: ..."
             case T.breakOn "::" line of
               (sigName, rest) | not (T.null rest) && not (T.isPrefixOf " " rawLine) ->
                 let cleanSig = T.strip sigName
                 in if isValidIdentifier cleanSig
                      then [Just $ TagEntry cleanSig fp lineNum TagFunction pat Nothing]
                      else []
               _ ->
                 -- Check for top-level definition "name arg1 ... = ..."
                 case T.breakOn "=" line of
                   (lhs, rest) | not (T.null rest) && not (T.isPrefixOf " " rawLine) ->
                     let lhsWords = T.words lhs
                     in case lhsWords of
                       (fnName : _) | isValidIdentifier fnName && not (isKeyword fnName) ->
                         [Just $ TagEntry fnName fp lineNum TagFunction pat Nothing]
                       _ -> []
                   _ -> []

-- | Extract symbols from a C source file.
extractCTags :: FilePath -> Text -> [TagEntry]
extractCTags fp content =
  let lns = zip [1..] (T.lines content)
  in catMaybes (concatMap (parseCLine fp) lns)

parseCLine :: FilePath -> (Int, Text) -> [Maybe TagEntry]
parseCLine fp (lineNum, rawLine) =
  let line = T.strip rawLine
      pat = "^" <> line <> "$"
  in if T.null line || "//" `T.isPrefixOf` line || "/*" `T.isPrefixOf` line
       then []
       else
         let ws = T.words line
         in case ws of
           ("#define" : macroName : _) ->
             let cleanMacro = fst (T.breakOn "(" macroName)
             in [Just $ TagEntry cleanMacro fp lineNum TagMacro pat Nothing]

           ("struct" : structName : _) ->
             let cleanStruct = fst (T.breakOn "{" structName)
             in if not (T.null cleanStruct) && isValidIdentifier cleanStruct
                  then [Just $ TagEntry cleanStruct fp lineNum TagData pat Nothing]
                  else []

           _ ->
             -- Look for function definition "ret_type name(args) {"
             if "(" `T.isInfixOf` line && not (T.isPrefixOf " " rawLine) && not (T.isPrefixOf "#" line)
               then
                 let beforeParen = fst (T.breakOn "(" line)
                     parts = T.words beforeParen
                 in case reverse parts of
                   (fnName : _ret : _) | isValidIdentifier fnName && not (isKeyword fnName) ->
                     [Just $ TagEntry fnName fp lineNum TagFunction pat Nothing]
                   _ -> []
               else []

isValidIdentifier :: Text -> Bool
isValidIdentifier t = case T.uncons t of
  Nothing -> False
  Just (c, rest) ->
    (isAlphaNum c || c == '_') && T.all (\ch -> isAlphaNum ch || ch == '_' || ch == '\'') rest

isKeyword :: Text -> Bool
isKeyword t = t `elem`
  [ "module", "data", "newtype", "type", "class", "instance", "where", "let", "in", "do", "case", "of"
  , "if", "then", "else", "import", "qualified", "as", "foreign", "default", "deriving"
  , "struct", "typedef", "return", "while", "for", "switch", "static", "const", "void", "int"
  ]

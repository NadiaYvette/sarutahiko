{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Tags.Format
-- Description : Serialization for ctags tab-delimited and universal-ctags JSON Lines
--
-- Emits symbol index entries conforming to Universal Ctags specification
-- and traditional Vi/Ex tags formats.
module Sarutahiko.Tags.Format
  ( formatUniversalCtagsJson
  , formatViCtagsLine
  , formatTagsFile
  , formatTagsJsonLines
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Sarutahiko.Tags.Types

-- | Format a single tag entry into Universal Ctags JSON Line.
formatUniversalCtagsJson :: TagEntry -> ByteString
formatUniversalCtagsJson entry =
  "{\"_type\":\"tag\",\"name\":\"" <> escapeJson (tagName entry)
  <> "\",\"path\":\"" <> escapeJson (T.pack (tagPath entry))
  <> "\",\"pattern\":\"" <> escapeJson (tagPattern entry)
  <> "\",\"line\":" <> BSC.pack (show (tagLine entry))
  <> ",\"kind\":\"" <> TE.encodeUtf8 (tagKindName (tagKind entry))
  <> "\"}"

-- | Format a single tag entry into traditional Vi/Ex tab-delimited format.
--
-- Layout: @<name> \t <path> \t /<pattern>/;" \t <kindChar>@
formatViCtagsLine :: TagEntry -> ByteString
formatViCtagsLine entry =
  TE.encodeUtf8 (tagName entry) <> "\t"
  <> BSC.pack (tagPath entry) <> "\t"
  <> "/" <> TE.encodeUtf8 (tagPattern entry) <> "/;\"\t"
  <> BSC.singleton (tagKindChar (tagKind entry))

-- | Format a list of tags into a complete Vi ctags file with header.
formatTagsFile :: [TagEntry] -> ByteString
formatTagsFile tags =
  let header =
        [ "!_TAG_FILE_FORMAT\t2\t/extended format/"
        , "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/"
        , "!_TAG_PROGRAM_AUTHOR\tNadia Yvette Chambers\t/nadia.yvette.chambers@ik.me/"
        , "!_TAG_PROGRAM_NAME\tsarutahiko-tags\t//"
        , "!_TAG_PROGRAM_VERSION\t0.1.0.0\t//"
        ]
      tagLines = map formatViCtagsLine tags
  in BSC.unlines (header ++ tagLines)

-- | Format a list of tags into Universal Ctags JSON Lines.
formatTagsJsonLines :: [TagEntry] -> ByteString
formatTagsJsonLines tags =
  BSC.unlines (map formatUniversalCtagsJson tags)

-- | Helper escaping JSON characters.
escapeJson :: Text -> ByteString
escapeJson txt = TE.encodeUtf8 $ T.concatMap escapeChar txt
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = T.singleton c

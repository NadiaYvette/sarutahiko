{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Module      : Yamaarashi.Flow.PacketCodec
-- Description : Resilient Ingress Codec for Task Packets & Prepared .gpatch Sketches
--
-- Dispatches YAML, Markdown, and Prepared .gpatch files resiliently into
-- typed TaskPacket envelopes.
module Yamaarashi.Flow.PacketCodec
  ( TaskPacket (..)
  , decodePacketResilient
  , isGpatchFile
  ) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.FilePath (takeBaseName, takeExtension)

import Darcs.Patch.Witnesses (Sealed2 (..))
import Gargamelle.Evidence.Patch.Prim (unPatchId)
import Gargamelle.Evidence.Patch.Bundle (GPatch (..), readGPatchBundle)
import Yamaarashi.Flow.Types

-- | Parsed task packet envelope.
data TaskPacket = TaskPacket
  { packetId                :: !Text
  , packetTitle             :: !Text
  , packetDescription       :: !Text
  , packetPackages          :: ![Text]
  , packetExecutor          :: !Text
  , packetModel             :: !(Maybe Text)
  , packetSkills            :: ![Text]
  , packetMaxTurns          :: !(Maybe Int)
  , packetRunBudget         :: !(Maybe Int)
  , packetMaxRepairAttempts :: !(Maybe Int)
  , packetAllowMetered      :: !Bool
  , packetRawYaml           :: !Text
  } deriving (Show, Eq)

-- | Check whether a file is a .gpatch bundle.
isGpatchFile :: FilePath -> Bool
isGpatchFile path = takeExtension path == ".gpatch"

-- | Resiliently decode a task packet file (YAML, Markdown, or .gpatch).
decodePacketResilient :: FilePath -> IO (TaskPacket, Maybe FilePath)
decodePacketResilient path
  | isGpatchFile path = do
      sealed <- readGPatchBundle path
      case sealed of
        Sealed2 (gp :: GPatch wX wY) -> do
          let pId = TE.decodeUtf8 (unPatchId (gpPatchId gp))
              packet = TaskPacket
                { packetId                = pId
                , packetTitle             = "Prepared Sketch: " <> pId
                , packetDescription       = "Inbound prepared .gpatch sketch bundle"
                , packetPackages          = []
                , packetExecutor          = "auto"
                , packetModel             = Nothing
                , packetSkills            = []
                , packetMaxTurns          = Just 4
                , packetRunBudget         = Just 500
                , packetMaxRepairAttempts = Just 3
                , packetAllowMetered      = False
                , packetRawYaml           = "id: \"" <> pId <> "\"\ngpatch: \"" <> T.pack path <> "\"\n"
                }
          pure (packet, Just path)
  | otherwise = do
      content <- TIO.readFile path
      let baseId = T.pack (takeBaseName path)
          gpatchRef = findGpatchRef content
      pure (parseBasicYaml baseId content, gpatchRef)

findGpatchRef :: Text -> Maybe FilePath
findGpatchRef txt =
  let lns = T.lines txt
      matches = [ T.unpack (T.strip (T.drop 7 l)) | l <- lns, "gpatch:" `T.isPrefixOf` l ]
  in case matches of
       (m:_) -> Just (filter (/= '"') (filter (/= '\'') m))
       []    -> Nothing

parseBasicYaml :: Text -> Text -> TaskPacket
parseBasicYaml fallbackId txt =
  let lns = T.lines txt
      stripQuotes s =
        let t = T.strip s
        in if (T.isPrefixOf "\"" t && T.isSuffixOf "\"" t && T.length t >= 2)
           || (T.isPrefixOf "'" t && T.isSuffixOf "'" t && T.length t >= 2)
             then T.drop 1 (T.dropEnd 1 t)
             else t
      findVal key = case filter (T.isPrefixOf (key <> ":")) lns of
        (l:_) -> stripQuotes (T.strip (T.drop (T.length key + 1) l))
        []    -> ""
      extractList key =
        let afterKey = drop 1 $ dropWhile (\l -> not (T.isPrefixOf (key <> ":") l)) lns
            items = takeWhile (\l -> T.isPrefixOf "  - " l || T.isPrefixOf "- " l) afterKey
            clean l = stripQuotes (T.strip (T.dropWhile (\c -> c == ' ' || c == '-') (fst (T.breakOn "#" l))))
        in filter (not . T.null) (map clean items)
      pId = let v = findVal "id" in if T.null v then fallbackId else v
      pTitle = let v = findVal "title" in if T.null v then pId else v
      pDesc = findVal "description"
      pPackages = extractList "packages"
      pExec = let v = findVal "executor" in if T.null v then "auto" else v
  in TaskPacket
    { packetId                = pId
    , packetTitle             = pTitle
    , packetDescription       = pDesc
    , packetPackages          = pPackages
    , packetExecutor          = pExec
    , packetModel             = Nothing
    , packetSkills            = []
    , packetMaxTurns          = Just 8
    , packetRunBudget         = Just 800
    , packetMaxRepairAttempts = Just 4
    , packetAllowMetered      = False
    , packetRawYaml           = txt
    }

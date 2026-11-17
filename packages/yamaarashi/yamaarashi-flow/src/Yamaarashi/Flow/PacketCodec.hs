{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Module      : Yamaarashi.Flow.PacketCodec
-- Description : Resilient Ingress Codec for Task Packets, Dhall Manifests, & Prepared .gpatch Sketches
--
-- Dispatches YAML, Markdown, typed Dhall, and Prepared .gpatch files resiliently into
-- typed TaskPacket envelopes.
module Yamaarashi.Flow.PacketCodec
  ( TaskPacket (..)
  , decodePacketResilient
  , isGpatchFile
  , isDhallFile
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName, takeExtension)
import System.Process.Typed (proc, readProcess)

import Darcs.Patch.Witnesses (Sealed2 (..))
import Gargamelle.Evidence.Patch.Prim (unPatchId)
import Gargamelle.Evidence.Patch.Bundle (GPatch (..), readGPatchBundle)

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
  , packetSeedFiles         :: ![FilePath]
  , packetRawYaml           :: !Text
  } deriving (Show, Eq)

-- | Check whether a file is a .gpatch bundle.
isGpatchFile :: FilePath -> Bool
isGpatchFile path = takeExtension path == ".gpatch"

-- | Check whether a file is a Dhall manifest.
isDhallFile :: FilePath -> Bool
isDhallFile path = takeExtension path == ".dhall"

-- | Resiliently decode a task packet file (Dhall, YAML, Markdown, or .gpatch).
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
                , packetSeedFiles         = []
                , packetRawYaml           = "id: \"" <> pId <> "\"\ngpatch: \"" <> T.pack path <> "\"\n"
                }
          pure (packet, Just path)
  | isDhallFile path = do
      mDhallToJson <- findExecutable "dhall-to-json"
      case mDhallToJson of
        Just bin -> do
          (code, outBs, _) <- readProcess (proc bin ["--file", path])
          case code of
            ExitSuccess ->
              case Aeson.decode outBs of
                Just (Aeson.Object obj) -> do
                  let baseId = T.pack (takeBaseName path)
                      extractTxt k = case KM.lookup k obj of
                        Just (Aeson.String s) -> s
                        _                     -> ""
                      extractListKey k = case KM.lookup k obj of
                        Just (Aeson.Array arr) ->
                          [ s | Aeson.String s <- concatMap (\case { Aeson.String s -> [Aeson.String s]; _ -> [] }) arr ]
                        _ -> []
                      extractInt k = case KM.lookup k obj of
                        Just (Aeson.Number n) -> Just (round n)
                        _                     -> Nothing
                      extractBool k def = case KM.lookup k obj of
                        Just (Aeson.Bool b) -> b
                        _                   -> def
                      pId = let v = extractTxt "id" in if T.null v then baseId else v
                      pTitle = let v = extractTxt "title" in if T.null v then pId else v
                      pDesc = let v = extractTxt "description"
                              in if T.null v then extractTxt "instructions" else v
                      pPkgs = extractListKey "packages"
                      pExec = let v = extractTxt "executor" in if T.null v then "auto" else v
                      pModel = let v = extractTxt "model" in if T.null v then Nothing else Just v
                      pSkills = extractListKey "skills"
                      pMaxTurns = extractInt "maxTurns"
                      pBudget = extractInt "runBudgetSeconds"
                      pMaxRepair = extractInt "maxRepairAttempts"
                      pAllowMetered = extractBool "allowMetered" False
                      pSeeds = map T.unpack (extractListKey "seeds" ++ extractListKey "seed_files")
                      rawYaml = TE.decodeUtf8 (BSL.toStrict outBs)
                      pkt = TaskPacket
                        { packetId                = pId
                        , packetTitle             = pTitle
                        , packetDescription       = pDesc
                        , packetPackages          = pPkgs
                        , packetExecutor          = pExec
                        , packetModel             = pModel
                        , packetSkills            = pSkills
                        , packetMaxTurns          = pMaxTurns
                        , packetRunBudget         = pBudget
                        , packetMaxRepairAttempts = pMaxRepair
                        , packetAllowMetered      = pAllowMetered
                        , packetSeedFiles         = pSeeds
                        , packetRawYaml           = rawYaml
                        }
                  pure (pkt, Nothing)
                _ -> fallbackYaml path
            _ -> fallbackYaml path
        Nothing -> fallbackYaml path
  | otherwise = fallbackYaml path
  where
    fallbackYaml p = do
      content <- TIO.readFile p
      let baseId = T.pack (takeBaseName p)
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
      pSeeds = map T.unpack (extractList "seeds" ++ extractList "seed_files")
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
    , packetSeedFiles         = pSeeds
    , packetRawYaml           = txt
    }

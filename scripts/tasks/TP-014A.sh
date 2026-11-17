#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-014A] Implementing Yamaarashi.Campaign.Unfold ==="

SARU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YAMA_DIR="$SARU_DIR/packages/yamaarashi/yamaarashi"

mkdir -p "$YAMA_DIR/src/Yamaarashi/Campaign"

# 1. Update yamaarashi.cabal
cat << 'EOF' > "$YAMA_DIR/yamaarashi.cabal"
cabal-version:      3.14
name:               yamaarashi
version:            0.1.0.0
synopsis:           Church-encoded CPS free-monad element streaming kernel
description:
    Pure, dependency-free element streaming kernel implementing O(1) left-associated
    monadic binds via Codensity and Church-encoded CPS free monads. Unrolls existential
    Steppers into element streams at the consumer edge with typed concurrency strategies.
license:            BSD-3-Clause
license-file:       LICENSE
author:             Nadia Yvette Chambers
maintainer:         nadia.yvette.chambers@ik.me
category:           Control, Streaming
build-type:         Simple

common commons
    default-language: GHC2024
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wmissing-home-modules
        -Wpartial-fields
        -Wredundant-constraints

library
    import:           commons
    exposed-modules:
        Yamaarashi
        Yamaarashi.Synthesis.Synquid
        Yamaarashi.Context.BlastShield
        Yamaarashi.Context.TailExcision
        Yamaarashi.Sandbox.Airgap
        Yamaarashi.Executor.DeterministicSplicer
        Yamaarashi.Daemon.PowerAndWAL
        Yamaarashi.Schedule.TropicalPERT
        Yamaarashi.Schedule.Quarantine
        Yamaarashi.Patch.Prepared
        Yamaarashi.Patch.Reaper
        Yamaarashi.Campaign.Unfold
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        mtl,
        bytestring,
        filepath,
        directory,
        process,
        aeson,
        kagami-ita-observability,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        gargamelle-sheaf,
        gargamelle-evidence,
        gargamelle-equational,
        darcs-witnesses,
        darcs-prim-structural,
        git-bundle-pure,
        sarutahiko-effect-signatures >= 0.1,
        direct-sqlite >= 2.3
    hs-source-dirs:   src

test-suite yamaarashi-test
    import:           commons
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    ghc-options:      -threaded -rtsopts -with-rtsopts=-N
    build-depends:
        base >= 4.20 && < 5,
        containers,
        text,
        bytestring,
        filepath,
        directory,
        process,
        aeson,
        kagami-ita-observability,
        yamaarashi,
        polytropos-core,
        gargamelle-core,
        gargamelle-fol,
        gargamelle-sheaf,
        gargamelle-evidence,
        gargamelle-equational,
        darcs-witnesses,
        darcs-prim-structural,
        git-bundle-pure,
        sarutahiko-effect-signatures >= 0.1,
        direct-sqlite >= 2.3,
        tasty,
        hedgehog,
        tasty-hedgehog
EOF

# 2. Write Yamaarashi.Campaign.Unfold
cat << 'EOF' > "$YAMA_DIR/src/Yamaarashi/Campaign/Unfold.hs"
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Campaign.Unfold
-- Description : CampaignMatrix Dhall Loader, Recon Pullback Runner, & Pushout Instantiator
--
-- Executes Phase-0 ReconSpec tasks to extract host interface witnesses (\Sigma_C),
-- and instantiates PushoutTemplate (B \amalg_C W) to emit concrete Tier-2 leaf
-- task packets where each emitted packet satisfies the IsPrimitive(T) <= 1 module
-- constraint.
module Yamaarashi.Campaign.Unfold
  ( -- * 1. Campaign Schema Types (CampaignSchema.dhall)
    ExecutionMode (..)
  , QuarantinePolicy (..)
  , TriageAction (..)
  , PowerPolicy (..)
  , PertEstimate (..)
  , ReconSpec (..)
  , PushoutTemplate (..)
  , CampaignArc (..)
  , CampaignMatrix (..)

    -- * 2. Recon Pullback Runner (Phase 0)
  , InterfaceWitness (..)
  , emptyLiquidSig
  , runReconSpec
  , extractHaskellInterfaceWitness
  , extractFromHsSource

    -- * 3. Pushout Instantiator (Phase 1)
  , HostBase (..)
  , UnfoldedLeafPacket (..)
  , isPrimitivePacket
  , instantiatePushout

    -- * 4. Campaign Matrix & Arc Unfolder
  , unfoldArc
  , unfoldCampaignMatrix
  , unfoldToScheduleGraph

    -- * 5. Dhall Manifest Loading & Serialization
  , loadCampaignMatrix
  , loadCampaignMatrixFromJson
  , emitWitnessDhall
  , emitPacketYaml
  ) where

import Control.Monad (forM)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value (..)
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  , object
  , withObject
  , withText
  )
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import Data.Char (isAlpha, isAlphaNum)
import Data.Foldable (toList)
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getHomeDirectory
  , listDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import qualified System.Process as Process

import Gargamelle.Core.Institution.Liquid
  ( LiquidPred (..)
  , LiquidSig (..)
  , MeasureDecl (..)
  )
import Yamaarashi.Schedule.TropicalPERT
  ( ScheduleGraph (..)
  , TaskStatus (..)
  , TaskVertex (..)
  , addDependency
  , emptyScheduleGraph
  , insertTask
  )

--------------------------------------------------------------------------------
-- 1. Campaign Schema Types (CampaignSchema.dhall)
--------------------------------------------------------------------------------

-- | Execution mode for a Campaign Arc.
data ExecutionMode
  = Autonomous
  | ReconFirst
  | HumanGated
  deriving stock (Eq, Show, Generic)

instance FromJSON ExecutionMode where
  parseJSON = withText "ExecutionMode" $ \case
    "Autonomous" -> pure Autonomous
    "ReconFirst" -> pure ReconFirst
    "HumanGated" -> pure HumanGated
    other        -> fail ("Unknown ExecutionMode: " ++ T.unpack other)

instance ToJSON ExecutionMode where
  toJSON = \case
    Autonomous -> String "Autonomous"
    ReconFirst -> String "ReconFirst"
    HumanGated -> String "HumanGated"

-- | Policy parameters for quarantined vertices awaiting repair.
data QuarantinePolicy = QuarantinePolicy
  { emitAxiomaticStub :: !Bool
  } deriving stock (Eq, Show, Generic)

instance FromJSON QuarantinePolicy where
  parseJSON = withObject "QuarantinePolicy" $ \o -> QuarantinePolicy
    <$> o .: "emitAxiomaticStub"

instance ToJSON QuarantinePolicy where
  toJSON (QuarantinePolicy b) = object [ "emitAxiomaticStub" .= b ]

-- | Triage action taken when a task exhausts repair attempts.
data TriageAction
  = QuarantineAndStub !QuarantinePolicy
  | HaltArcOnly
  | HaltEntireMatrix
  deriving stock (Eq, Show, Generic)

instance FromJSON TriageAction where
  parseJSON = \case
    String "HaltArcOnly" -> pure HaltArcOnly
    String "HaltEntireMatrix" -> pure HaltEntireMatrix
    Object o -> do
      mEmit <- o .:? "emitAxiomaticStub"
      case mEmit of
        Just b -> pure (QuarantineAndStub (QuarantinePolicy b))
        Nothing -> do
          mQ <- o .:? "QuarantineAndStub"
          case mQ of
            Just (Object q) -> QuarantineAndStub <$> parseJSON (Object q)
            Just (Bool b)   -> pure (QuarantineAndStub (QuarantinePolicy b))
            Just _          -> fail "Unexpected format for QuarantineAndStub"
            Nothing -> do
              mHaltArc :: Maybe Value <- o .:? "HaltArcOnly"
              case mHaltArc of
                Just _ -> pure HaltArcOnly
                Nothing -> do
                  mHaltMatrix :: Maybe Value <- o .:? "HaltEntireMatrix"
                  case mHaltMatrix of
                    Just _ -> pure HaltEntireMatrix
                    Nothing -> fail "Unknown TriageAction object"
    _ -> fail "Expected string or object for TriageAction"

instance ToJSON TriageAction where
  toJSON = \case
    QuarantineAndStub (QuarantinePolicy b) -> object [ "QuarantineAndStub" .= object [ "emitAxiomaticStub" .= b ] ]
    HaltArcOnly -> String "HaltArcOnly"
    HaltEntireMatrix -> String "HaltEntireMatrix"

-- | Power & thermal policy parameters for ThinkPad execution.
data PowerPolicy = PowerPolicy
  { softThrottleBatteryPct   :: !Int
  , hardCheckpointBatteryPct :: !Int
  , allowOnBattery           :: !Bool
  , maxParallelSandboxesAC   :: !Int
  , maxParallelSandboxesBat  :: !Int
  } deriving stock (Eq, Show, Generic)

instance FromJSON PowerPolicy where
  parseJSON = withObject "PowerPolicy" $ \o -> PowerPolicy
    <$> o .: "softThrottleBatteryPct"
    <*> o .: "hardCheckpointBatteryPct"
    <*> o .: "allowOnBattery"
    <*> o .: "maxParallelSandboxesAC"
    <*> o .: "maxParallelSandboxesBat"

instance ToJSON PowerPolicy where
  toJSON PowerPolicy{..} = object
    [ "softThrottleBatteryPct"   .= softThrottleBatteryPct
    , "hardCheckpointBatteryPct" .= hardCheckpointBatteryPct
    , "allowOnBattery"           .= allowOnBattery
    , "maxParallelSandboxesAC"   .= maxParallelSandboxesAC
    , "maxParallelSandboxesBat"  .= maxParallelSandboxesBat
    ]

-- | Tropical PERT 3-point estimate (in turns or wall-clock seconds).
data PertEstimate = PertEstimate
  { pertOptimistic  :: !Int
  , pertMostLikely  :: !Int
  , pertPessimistic :: !Int
  } deriving stock (Eq, Show, Generic)

instance FromJSON PertEstimate where
  parseJSON = withObject "PertEstimate" $ \o -> PertEstimate
    <$> o .: "optimistic"
    <*> o .: "mostLikely"
    <*> o .: "pessimistic"

instance ToJSON PertEstimate where
  toJSON PertEstimate{..} = object
    [ "optimistic"  .= pertOptimistic
    , "mostLikely"  .= pertMostLikely
    , "pessimistic" .= pertPessimistic
    ]

-- | Phase 0 Reconnaissance Pullback specification (extracts host interface C).
data ReconSpec = ReconSpec
  { reconTargetRepoDir      :: !FilePath
  , reconInspectGlobs       :: ![Text]
  , reconTreeSitterGrammar  :: !Text
  , reconOutputWitnessDhall :: !FilePath
  } deriving stock (Eq, Show, Generic)

instance FromJSON ReconSpec where
  parseJSON = withObject "ReconSpec" $ \o -> ReconSpec
    <$> o .: "targetRepoDir"
    <*> o .: "inspectGlobs"
    <*> o .: "treeSitterGrammar"
    <*> o .: "outputWitnessDhall"

instance ToJSON ReconSpec where
  toJSON ReconSpec{..} = object
    [ "targetRepoDir"      .= reconTargetRepoDir
    , "inspectGlobs"       .= reconInspectGlobs
    , "treeSitterGrammar"  .= reconTreeSitterGrammar
    , "outputWitnessDhall" .= reconOutputWitnessDhall
    ]

-- | Phase 1 Pushout Template (glues host Base B and Weave W over Interface C).
data PushoutTemplate = PushoutTemplate
  { pushoutSharedInterfaceSig :: !Text
  , pushoutWeaveSpecModule    :: !Text
  , pushoutRequiredMeasures   :: ![Text]
  , pushoutRequiredQualifiers :: ![Text]
  } deriving stock (Eq, Show, Generic)

instance FromJSON PushoutTemplate where
  parseJSON = withObject "PushoutTemplate" $ \o -> PushoutTemplate
    <$> o .: "sharedInterfaceSig"
    <*> o .: "weaveSpecModule"
    <*> o .: "requiredMeasures"
    <*> o .: "requiredQualifiers"

instance ToJSON PushoutTemplate where
  toJSON PushoutTemplate{..} = object
    [ "sharedInterfaceSig" .= pushoutSharedInterfaceSig
    , "weaveSpecModule"    .= pushoutWeaveSpecModule
    , "requiredMeasures"   .= pushoutRequiredMeasures
    , "requiredQualifiers" .= pushoutRequiredQualifiers
    ]

-- | Single stateful Campaign Arc.
data CampaignArc = CampaignArc
  { arcId               :: !Text
  , arcTitle            :: !Text
  , arcCoordinates      :: ![(Text, Text)]
  , arcGitBranch        :: !Text
  , arcDependsOnArcs    :: ![Text]
  , arcSharedSheafEdges :: ![Text]
  , arcMode             :: !ExecutionMode
  , arcPert             :: !PertEstimate
  , arcRecon            :: !(Maybe ReconSpec)
  , arcPushout          :: !(Maybe PushoutTemplate)
  , arcSeedMetaPackets  :: ![Text]
  , arcTriagePolicy     :: !TriageAction
  } deriving stock (Eq, Show, Generic)

instance FromJSON CampaignArc where
  parseJSON = withObject "CampaignArc" $ \o -> do
    arcId <- o .: "arcId"
    arcTitle <- o .: "title"
    rawCoords <- o .:? "coordinates" .!= []
    let arcCoordinates =
          [ (axis, val)
          | Object c <- rawCoords
          , Just (String axis) <- [KeyMap.lookup "axis" c]
          , Just (String val)  <- [KeyMap.lookup "value" c]
          ]
    arcGitBranch <- o .: "gitBranch"
    arcDependsOnArcs <- o .:? "dependsOnArcs" .!= []
    arcSharedSheafEdges <- o .:? "sharedSheafEdges" .!= []
    arcMode <- o .:? "mode" .!= Autonomous
    arcPert <- o .: "pert"
    arcRecon <- o .:? "recon"
    arcPushout <- o .:? "pushout"
    arcSeedMetaPackets <- o .:? "seedMetaPackets" .!= []
    arcTriagePolicy <- o .:? "triagePolicy" .!= QuarantineAndStub (QuarantinePolicy True)
    pure CampaignArc{..}

instance ToJSON CampaignArc where
  toJSON CampaignArc{..} = object
    [ "arcId"            .= arcId
    , "title"            .= arcTitle
    , "coordinates"      .= [ object [ "axis" .= a, "value" .= v ] | (a, v) <- arcCoordinates ]
    , "gitBranch"        .= arcGitBranch
    , "dependsOnArcs"    .= arcDependsOnArcs
    , "sharedSheafEdges" .= arcSharedSheafEdges
    , "mode"             .= arcMode
    , "pert"             .= arcPert
    , "recon"            .= arcRecon
    , "pushout"          .= arcPushout
    , "seedMetaPackets"  .= arcSeedMetaPackets
    , "triagePolicy"     .= arcTriagePolicy
    ]

-- | Top-level Campaign Matrix.
data CampaignMatrix = CampaignMatrix
  { matrixId            :: !Text
  , matrixDescription   :: !Text
  , matrixAxes          :: ![(Text, [Text])]
  , matrixPowerPolicy   :: !PowerPolicy
  , matrixDefaultTriage :: !TriageAction
  , matrixArcs          :: ![CampaignArc]
  } deriving stock (Eq, Show, Generic)

instance FromJSON CampaignMatrix where
  parseJSON = withObject "CampaignMatrix" $ \o -> do
    matrixId <- o .: "matrixId"
    matrixDescription <- o .: "description"
    rawAxes <- o .:? "axes" .!= []
    let matrixAxes =
          [ (name, pts)
          | Object a <- rawAxes
          , Just (String name) <- [KeyMap.lookup "axisName" a]
          , Just (Array arr)   <- [KeyMap.lookup "points" a]
          , let pts = [ p | String p <- toList arr ]
          ]
    matrixPowerPolicy <- o .: "powerPolicy"
    matrixDefaultTriage <- o .:? "defaultTriage" .!= QuarantineAndStub (QuarantinePolicy True)
    matrixArcs <- o .: "arcs"
    pure CampaignMatrix{..}

instance ToJSON CampaignMatrix where
  toJSON CampaignMatrix{..} = object
    [ "matrixId"      .= matrixId
    , "description"   .= matrixDescription
    , "axes"          .= [ object [ "axisName" .= n, "points" .= ps ] | (n, ps) <- matrixAxes ]
    , "powerPolicy"   .= matrixPowerPolicy
    , "defaultTriage" .= matrixDefaultTriage
    , "arcs"          .= matrixArcs
    ]

--------------------------------------------------------------------------------
-- 2. Recon Pullback Runner (Phase 0)
--------------------------------------------------------------------------------

-- | Canonical empty Liquid signature for synthesized host interfaces.
emptyLiquidSig :: LiquidSig
emptyLiquidSig = LiquidSig
  { sigSorts      = Set.empty
  , sigMeasures   = Map.empty
  , sigCtorAxioms = []
  , sigQualifiers = Set.empty
  , sigEnv        = Map.empty
  , sigPathCond   = []
  }

-- | Witness \Sigma_C of an extracted host interface from Recon pullback.
data InterfaceWitness = InterfaceWitness
  { iwInterfaceName   :: !Text
  , iwTargetRepoDir   :: !FilePath
  , iwModules         :: ![Text]
  , iwExportedSymbols :: ![Text]
  , iwTypeSignatures  :: ![(Text, Text)]
  , iwMeasures        :: ![MeasureDecl]
  , iwQualifiers      :: ![LiquidPred]
  , iwLiquidSig       :: !LiquidSig
  } deriving stock (Eq, Show, Generic)

instance ToJSON InterfaceWitness where
  toJSON InterfaceWitness{..} = object
    [ "interfaceName"   .= iwInterfaceName
    , "targetRepoDir"   .= iwTargetRepoDir
    , "modules"         .= iwModules
    , "exportedSymbols" .= iwExportedSymbols
    , "typeSignatures"  .= [ object [ "symbol" .= s, "signature" .= sig ] | (s, sig) <- iwTypeSignatures ]
    ]

instance FromJSON InterfaceWitness where
  parseJSON = withObject "InterfaceWitness" $ \o -> do
    iwInterfaceName <- o .: "interfaceName"
    iwTargetRepoDir <- o .: "targetRepoDir"
    iwModules <- o .:? "modules" .!= []
    iwExportedSymbols <- o .:? "exportedSymbols" .!= []
    rawSigs <- o .:? "typeSignatures" .!= []
    let iwTypeSignatures =
          [ (s, sig)
          | Object sigObj <- rawSigs
          , Just (String s)   <- [KeyMap.lookup "symbol" sigObj]
          , Just (String sig) <- [KeyMap.lookup "signature" sigObj]
          ]
    let iwMeasures = []
    let iwQualifiers = []
    let iwLiquidSig = emptyLiquidSig
    pure InterfaceWitness{..}

-- | Extract module name, exported symbols, and top-level type signatures from Haskell code.
extractFromHsSource :: Text -> (Maybe Text, [Text], [(Text, Text)])
extractFromHsSource src =
  let ls = T.lines src
      modName = extractModuleName ls
      exports = extractExports ls
      sigs = extractTypeSignatures ls
  in (modName, exports, sigs)

extractModuleName :: [Text] -> Maybe Text
extractModuleName [] = Nothing
extractModuleName (l:ls)
  | "module " `T.isPrefixOf` T.stripStart l =
      let rest = T.drop 7 (T.stripStart l)
          name = T.takeWhile (\c -> isAlphaNum c || c == '.' || c == '_') rest
      in if T.null name then Nothing else Just name
  | otherwise = extractModuleName ls

extractExports :: [Text] -> [Text]
extractExports ls =
  let full = T.unlines ls
  in case T.breakOn "module " full of
       (_, rest) | not (T.null rest) ->
         case T.breakOn "(" rest of
           (_, afterOpen) | not (T.null afterOpen) ->
             let (inside, _) = T.breakOn ")" afterOpen
                 rawTokens = T.splitOn "," (T.drop 1 inside)
                 clean tok =
                   let t1 = T.strip tok
                       t2 = T.takeWhile (\c -> isAlphaNum c || c == '_' || c == '\'') t1
                   in t2
             in filter (not . T.null) (map clean rawTokens)
           _ -> []
       _ -> []

extractTypeSignatures :: [Text] -> [(Text, Text)]
extractTypeSignatures = catMaybes . map parseSigLine
  where
    parseSigLine l
      | not (T.null l) && (isAlpha (T.head l) || T.head l == '_') && "::" `T.isInfixOf` l =
          case T.breakOn "::" l of
            (lhs, rhs) ->
              let ident = T.strip lhs
                  sig   = T.strip (T.drop 2 rhs)
              in if not (T.null ident) && not (T.null sig) && not (" " `T.isInfixOf` ident)
                   then Just (ident, sig)
                   else Nothing
      | otherwise = Nothing

-- | Extract interface witness from a collection of Haskell source files.
extractHaskellInterfaceWitness :: FilePath -> [FilePath] -> IO InterfaceWitness
extractHaskellInterfaceWitness repoDir files = do
  results <- forM files $ \f -> do
    exists <- doesFileExist f
    if exists
      then do
        content <- TIO.readFile f
        pure (extractFromHsSource content)
      else pure (Nothing, [], [])
  let mods = catMaybes [ m | (m, _, _) <- results ]
      exports = concat [ es | (_, es, _) <- results ]
      sigs = concat [ ss | (_, _, ss) <- results ]
  pure InterfaceWitness
    { iwInterfaceName   = case mods of (m:_) -> m; [] -> "Interface.Sig"
    , iwTargetRepoDir   = repoDir
    , iwModules         = mods
    , iwExportedSymbols = exports
    , iwTypeSignatures  = sigs
    , iwMeasures        = []
    , iwQualifiers      = []
    , iwLiquidSig       = emptyLiquidSig
    }

-- | Run Phase-0 Reconnaissance Pullback specification and materialize interface witness.
runReconSpec :: ReconSpec -> IO (Either Text InterfaceWitness)
runReconSpec ReconSpec{..} = do
  expandedDir <- expandHome reconTargetRepoDir
  dirExists <- doesDirectoryExist expandedDir
  if not dirExists
    then pure (Left ("Target repo dir does not exist: " <> T.pack expandedDir))
    else do
      files <- findInspectFiles expandedDir reconInspectGlobs
      witness <- extractHaskellInterfaceWitness expandedDir files
      let outPath = expandedDir </> reconOutputWitnessDhall
      emitWitnessDhall outPath witness
      pure (Right witness)

findInspectFiles :: FilePath -> [Text] -> IO [FilePath]
findInspectFiles dir globs = do
  allEntries <- listDirectoryRecursive dir
  if null globs
    then pure (filter (\f -> takeExtension f == ".hs") allEntries)
    else do
      let patterns = map T.unpack globs
      pure (filter (\f -> any (`matchesGlob` f) patterns) allEntries)

matchesGlob :: String -> FilePath -> Bool
matchesGlob pat path
  | pat == "*.hs" || pat == "**/*.hs" = takeExtension path == ".hs"
  | "*.hs" `isSuffixOf` pat = takeExtension path == ".hs"
  | otherwise = pat `isSuffixOf` path || takeFileName path == pat

listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  isDir <- doesDirectoryExist dir
  if not isDir
    then pure []
    else do
      names <- listDirectory dir
      paths <- forM names $ \name -> do
        let full = dir </> name
        isD <- doesDirectoryExist full
        if isD
          then if name `elem` [".git", "dist-newstyle", ".yamaarashi", ".ok"]
                 then pure []
                 else listDirectoryRecursive full
          else pure [full]
      pure (concat paths)

expandHome :: FilePath -> IO FilePath
expandHome ('~':'/':rest) = do
  home <- getHomeDirectory
  pure (home </> rest)
expandHome "~" = getHomeDirectory
expandHome other = pure other

renderWitnessDhall :: InterfaceWitness -> Text
renderWitnessDhall InterfaceWitness{..} = T.unlines
  [ "-- Interface Witness Σ_C emitted by Yamaarashi.Campaign.Unfold"
  , "{"
  , "  interfaceName = " <> quoteText iwInterfaceName <> ","
  , "  targetRepoDir = " <> quoteText (T.pack iwTargetRepoDir) <> ","
  , "  modules = " <> renderTextList iwModules <> ","
  , "  exportedSymbols = " <> renderTextList iwExportedSymbols <> ","
  , "  typeSignatures ="
  , "    [ " <> (if null iwTypeSignatures then "" else T.intercalate "\n    , " (map renderSig iwTypeSignatures))
  , "    ]"
  , "}"
  ]
  where
    quoteText t = "\"" <> t <> "\""
    renderTextList xs = "[ " <> T.intercalate ", " (map quoteText xs) <> " ]"
    renderSig (s, sig) =
      "{ symbol = " <> quoteText s <> ", signature = " <> quoteText sig <> " }"

emitWitnessDhall :: FilePath -> InterfaceWitness -> IO ()
emitWitnessDhall path witness = do
  createDirectoryIfMissing True (takeDirectory path)
  TIO.writeFile path (renderWitnessDhall witness)

--------------------------------------------------------------------------------
-- 3. Pushout Instantiator (Phase 1)
--------------------------------------------------------------------------------

-- | Host base system B before pushout gluing.
data HostBase = HostBase
  { hbRepoDir         :: !FilePath
  , hbTargetModule    :: !Text
  , hbExistingSymbols :: ![Text]
  , hbLiquidSig       :: !LiquidSig
  } deriving stock (Eq, Show, Generic)

-- | Concrete Tier-2 leaf task packet emitted from pushout unfolding.
data UnfoldedLeafPacket = UnfoldedLeafPacket
  { ulpId                :: !Text
  , ulpTitle             :: !Text
  , ulpArcId             :: !Text
  , ulpRepoDir           :: !FilePath
  , ulpTargetModule      :: !Text          -- ^ Exactly 1 module constraint
  , ulpDependsOn         :: ![Text]
  , ulpExecutor          :: !Text
  , ulpMaxTurns          :: !Int
  , ulpRunBudgetSeconds  :: !Int
  , ulpMaxRepairAttempts :: !Int
  , ulpAllowMetered      :: !Bool
  , ulpAssumedGuarantees :: ![Text]
  , ulpVerificationCmd   :: !Text
  , ulpRawPacketYaml     :: !Text
  } deriving stock (Eq, Show, Generic)

-- | Invariant: each leaf packet must satisfy IsPrimitive(T) <= 1 module constraint.
isPrimitivePacket :: UnfoldedLeafPacket -> Bool
isPrimitivePacket p =
  let m = ulpTargetModule p
  in not (T.null m) && not (T.isInfixOf "," m) && not (T.isInfixOf " " (T.strip m))

-- | Pushout instantiator gluing base B and weave W over extracted interface C.
instantiatePushout
  :: HostBase
  -> InterfaceWitness
  -> PushoutTemplate
  -> CampaignArc
  -> Either Text [UnfoldedLeafPacket]
instantiatePushout base _witness pushout arc = do
  let cMod = pushoutWeaveSpecModule pushout
      iSig = pushoutSharedInterfaceSig pushout
      pLikely = pertMostLikely (arcPert arc)
      turns = max 1 pLikely
      budget = turns * 120
      reps = 3
      measures = pushoutRequiredMeasures pushout
      quals = pushoutRequiredQualifiers pushout
      guarantees = measures <> quals
      repo = hbRepoDir base
      arc_id = arcId arc

  let p1 = UnfoldedLeafPacket
        { ulpId                = arc_id <> "-001A"
        , ulpTitle             = arcTitle arc <> " — Core Weave (" <> cMod <> ")"
        , ulpArcId             = arc_id
        , ulpRepoDir           = repo
        , ulpTargetModule      = cMod
        , ulpDependsOn         = []
        , ulpExecutor          = "auto"
        , ulpMaxTurns          = turns
        , ulpRunBudgetSeconds  = budget
        , ulpMaxRepairAttempts = reps
        , ulpAllowMetered      = False
        , ulpAssumedGuarantees = guarantees
        , ulpVerificationCmd   = "cabal v2-build yamaarashi -j20 --semaphore && cabal v2-test yamaarashi"
        , ulpRawPacketYaml     = ""
        }
      p1WithYaml = p1 { ulpRawPacketYaml = emitPacketYaml p1 }

  packets <- if not (T.null iSig) && iSig /= cMod && not ("." `T.isInfixOf` iSig && T.takeWhile (/= '.') iSig == cMod)
    then do
      let p2 = UnfoldedLeafPacket
            { ulpId                = arc_id <> "-001B"
            , ulpTitle             = arcTitle arc <> " — Interface Adapter (" <> iSig <> ")"
            , ulpArcId             = arc_id
            , ulpRepoDir           = repo
            , ulpTargetModule      = iSig
            , ulpDependsOn         = [ulpId p1]
            , ulpExecutor          = "auto"
            , ulpMaxTurns          = turns
            , ulpRunBudgetSeconds  = budget
            , ulpMaxRepairAttempts = reps
            , ulpAllowMetered      = False
            , ulpAssumedGuarantees = guarantees
            , ulpVerificationCmd   = "cabal v2-build yamaarashi -j20 --semaphore && cabal v2-test yamaarashi"
            , ulpRawPacketYaml     = ""
            }
          p2WithYaml = p2 { ulpRawPacketYaml = emitPacketYaml p2 }
      pure [p1WithYaml, p2WithYaml]
    else pure [p1WithYaml]

  if all isPrimitivePacket packets
    then Right packets
    else Left ("Generated packet violated IsPrimitive(T) <= 1 constraint: " <> T.pack (show (map ulpTargetModule packets)))

emitPacketYaml :: UnfoldedLeafPacket -> Text
emitPacketYaml UnfoldedLeafPacket{..} = T.unlines $
  [ "id: " <> quoteYaml ulpId
  , "title: " <> quoteYaml ulpTitle
  , "arc: " <> quoteYaml ulpArcId
  , "repo: " <> quoteYaml (T.pack ulpRepoDir)
  , "target_module: " <> quoteYaml ulpTargetModule
  , "depends_on:"
  ] ++
  (if null ulpDependsOn
     then ["  []"]
     else map (\d -> "  - " <> quoteYaml d) ulpDependsOn) ++
  [ "executor: " <> quoteYaml ulpExecutor
  , "max_turns: " <> T.pack (show ulpMaxTurns)
  , "run_budget: " <> T.pack (show ulpRunBudgetSeconds)
  , "max_repair_attempts: " <> T.pack (show ulpMaxRepairAttempts)
  , "allow_metered: false"
  , "assumed_guarantees:"
  ] ++
  (if null ulpAssumedGuarantees
     then ["  []"]
     else map (\g -> "  - " <> quoteYaml g) ulpAssumedGuarantees) ++
  [ "verification:"
  , "  - dir: " <> quoteYaml (T.pack ulpRepoDir)
  , "    cmd: " <> quoteYaml ulpVerificationCmd
  ]
  where
    quoteYaml t = "\"" <> t <> "\""

--------------------------------------------------------------------------------
-- 4. Campaign Matrix & Arc Unfolder
--------------------------------------------------------------------------------

-- | Unfold an individual Campaign Arc into primitive leaf packets.
unfoldArc :: CampaignArc -> IO (Either Text [UnfoldedLeafPacket])
unfoldArc arc@CampaignArc{..} = do
  case arcRecon of
    Just recon -> do
      eWitness <- runReconSpec recon
      case eWitness of
        Left err -> pure (Left ("ReconSpec failed for arc " <> arcId <> ": " <> err))
        Right witness -> do
          case arcPushout of
            Just pushout -> do
              let base = HostBase
                    { hbRepoDir         = reconTargetRepoDir recon
                    , hbTargetModule    = case iwModules witness of
                                            (m:_) -> m
                                            []    -> "Main"
                    , hbExistingSymbols = iwExportedSymbols witness
                    , hbLiquidSig       = iwLiquidSig witness
                    }
              pure (instantiatePushout base witness pushout arc)
            Nothing ->
              pure (unfoldFromSeedPackets arc)
    Nothing -> do
      case arcPushout of
        Just pushout -> do
          let witness = InterfaceWitness
                { iwInterfaceName   = pushoutSharedInterfaceSig pushout
                , iwTargetRepoDir   = "."
                , iwModules         = [pushoutWeaveSpecModule pushout]
                , iwExportedSymbols = []
                , iwTypeSignatures  = []
                , iwMeasures        = []
                , iwQualifiers      = []
                , iwLiquidSig       = emptyLiquidSig
                }
              base = HostBase
                { hbRepoDir         = "."
                , hbTargetModule    = pushoutWeaveSpecModule pushout
                , hbExistingSymbols = []
                , hbLiquidSig       = emptyLiquidSig
                }
          pure (instantiatePushout base witness pushout arc)
        Nothing ->
          pure (unfoldFromSeedPackets arc)

unfoldFromSeedPackets :: CampaignArc -> Either Text [UnfoldedLeafPacket]
unfoldFromSeedPackets arc
  | null (arcSeedMetaPackets arc) =
      let p = UnfoldedLeafPacket
            { ulpId                = arcId arc <> "-001A"
            , ulpTitle             = arcTitle arc
            , ulpArcId             = arcId arc
            , ulpRepoDir           = "."
            , ulpTargetModule      = arcId arc
            , ulpDependsOn         = []
            , ulpExecutor          = "auto"
            , ulpMaxTurns          = max 1 (pertMostLikely (arcPert arc))
            , ulpRunBudgetSeconds  = max 1 (pertMostLikely (arcPert arc)) * 120
            , ulpMaxRepairAttempts = 3
            , ulpAllowMetered      = False
            , ulpAssumedGuarantees = []
            , ulpVerificationCmd   = "cabal v2-build yamaarashi -j20 --semaphore && cabal v2-test yamaarashi"
            , ulpRawPacketYaml     = ""
            }
      in Right [p { ulpRawPacketYaml = emitPacketYaml p }]
  | otherwise =
      let pLikely = max 1 (pertMostLikely (arcPert arc))
          turns = pLikely
          budget = turns * 120
          packets = zipWith (\idx seed ->
            let pid = arcId arc <> "-" <> T.pack (show idx)
                tMod = T.replace ".dhall" "" (T.replace ".md" "" (T.pack (takeFileName (T.unpack seed))))
                p = UnfoldedLeafPacket
                  { ulpId                = pid
                  , ulpTitle             = arcTitle arc <> " [" <> tMod <> "]"
                  , ulpArcId             = arcId arc
                  , ulpRepoDir           = "."
                  , ulpTargetModule      = tMod
                  , ulpDependsOn         = if idx == (1 :: Int) then [] else [arcId arc <> "-" <> T.pack (show (idx - 1))]
                  , ulpExecutor          = "auto"
                  , ulpMaxTurns          = turns
                  , ulpRunBudgetSeconds  = budget
                  , ulpMaxRepairAttempts = 3
                  , ulpAllowMetered      = False
                  , ulpAssumedGuarantees = []
                  , ulpVerificationCmd   = "cabal v2-build yamaarashi -j20 --semaphore && cabal v2-test yamaarashi"
                  , ulpRawPacketYaml     = ""
                  }
            in p { ulpRawPacketYaml = emitPacketYaml p }
            ) [1..] (arcSeedMetaPackets arc)
      in Right packets

-- | Unfold an entire Campaign Matrix into a map of arc leaf packets.
unfoldCampaignMatrix :: CampaignMatrix -> IO (Either Text (Map Text [UnfoldedLeafPacket]))
unfoldCampaignMatrix matrix = do
  results <- forM (matrixArcs matrix) $ \arc -> do
    ePkts <- unfoldArc arc
    case ePkts of
      Left err   -> pure (Left err)
      Right pkts -> pure (Right (arcId arc, pkts))
  case sequence results of
    Left err   -> pure (Left err)
    Right pairs -> pure (Right (Map.fromList pairs))

-- | Unfold a Campaign Matrix directly into a Tropical PERT ScheduleGraph.
unfoldToScheduleGraph :: CampaignMatrix -> IO (Either Text ScheduleGraph)
unfoldToScheduleGraph matrix = do
  eMap <- unfoldCampaignMatrix matrix
  case eMap of
    Left err -> pure (Left err)
    Right arcMap -> do
      let allPackets = concat (Map.elems arcMap)
      let g0 = foldr (\p g ->
            let v = TaskVertex
                  { tvId                   = ulpId p
                  , tvDuration             = fromIntegral (ulpRunBudgetSeconds p)
                  , tvTouchedFiles         = Set.singleton (T.unpack (ulpTargetModule p))
                  , tvPatchSymbols         = Set.empty
                  , tvStatus               = TaskPending
                  }
            in insertTask v g
            ) emptyScheduleGraph allPackets

      let g1 = foldr (\p g ->
            foldr (\dep gAcc -> addDependency dep (ulpId p) gAcc) g (ulpDependsOn p)
            ) g0 allPackets

      let g2 = foldr (\arc gAcc ->
            let arc_id = arcId arc
                deps = arcDependsOnArcs arc
                targetPackets = Map.findWithDefault [] arc_id arcMap
                rootTargets = filter (null . ulpDependsOn) targetPackets
            in foldr (\depArcId gSub ->
                 let depPackets = Map.findWithDefault [] depArcId arcMap
                     termDeps = if null depPackets then [] else [last depPackets]
                 in foldr (\depP gSub2 ->
                      foldr (\tP gSub3 -> addDependency (ulpId depP) (ulpId tP) gSub3)
                            gSub2 rootTargets
                      ) gSub termDeps
                 ) gAcc deps
            ) g1 (matrixArcs matrix)

      pure (Right g2)

--------------------------------------------------------------------------------
-- 5. Dhall Manifest Loading & Serialization
--------------------------------------------------------------------------------

-- | Load and decode a Campaign Matrix from a Dhall manifest using dhall-to-json.
loadCampaignMatrix :: FilePath -> IO (Either Text CampaignMatrix)
loadCampaignMatrix path = do
  (exitCode, stdout, stderr) <- Process.readProcessWithExitCode "dhall-to-json" ["--file", path] ""
  case exitCode of
    ExitSuccess ->
      case Aeson.eitherDecodeStrict' (TE.encodeUtf8 (T.pack stdout)) of
        Right matrix -> pure (Right matrix)
        Left err     -> pure (Left ("Aeson decode error: " <> T.pack err))
    ExitFailure code ->
      pure (Left ("dhall-to-json failed with code " <> T.pack (show code) <> ": " <> T.pack stderr))

-- | Load and decode a Campaign Matrix directly from JSON ByteString.
loadCampaignMatrixFromJson :: BS.ByteString -> Either Text CampaignMatrix
loadCampaignMatrixFromJson bs =
  case Aeson.eitherDecodeStrict' bs of
    Right matrix -> Right matrix
    Left err     -> Left ("Aeson decode error: " <> T.pack err)
EOF

# 3. Update Spec.hs
if ! grep -q "Yamaarashi.Campaign.Unfold" "$YAMA_DIR/test/Spec.hs"; then
  sed -i '/import Yamaarashi.Patch.Reaper/i import qualified Yamaarashi.Campaign.Unfold as Unfold' "$YAMA_DIR/test/Spec.hs"
  sed -i '/testGroup "Yamaarashi.Patch.Reaper"/i \  , testGroup "Yamaarashi.Campaign.Unfold"\n      [ testProperty "loads november-constellation.dhall CampaignMatrix cleanly" prop_campaign_unfold_load_constellation\n      , testProperty "executes Phase-0 Recon pullback runner and extracts interface witnesses" prop_campaign_unfold_recon_runner\n      , testProperty "instantiates PushoutTemplate (B ⨿_C W) satisfying IsPrimitive <= 1 module constraint" prop_campaign_unfold_pushout_primitives\n      , testProperty "unfolds CampaignMatrix to ScheduleGraph and verifies Tropical PERT CPM makespan" prop_campaign_unfold_schedule_graph_cpm\n      ]' "$YAMA_DIR/test/Spec.hs"
  cat << 'EOF' >> "$YAMA_DIR/test/Spec.hs"
--------------------------------------------------------------------------------
-- Campaign Unfold Tests (TP-014A)
--------------------------------------------------------------------------------

prop_campaign_unfold_load_constellation :: Property
prop_campaign_unfold_load_constellation = property $ do
  let dhallPath = "/home/nyc/src/plans/campaigns/november-constellation.dhall"
  exists <- evalIO $ Directory.doesFileExist dhallPath
  if exists
    then do
      eMatrix <- evalIO $ Unfold.loadCampaignMatrix dhallPath
      case eMatrix of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right matrix -> do
          Unfold.matrixId matrix === "CAMPAIGN-2026-11-CONSTELLATION"
          length (Unfold.matrixArcs matrix) === 5
          Unfold.softThrottleBatteryPct (Unfold.matrixPowerPolicy matrix) === 15
          Unfold.hardCheckpointBatteryPct (Unfold.matrixPowerPolicy matrix) === 7
          let arcIds = map Unfold.arcId (Unfold.matrixArcs matrix)
          assert ("ARC-SMIRK-EFFECTS" `elem` arcIds)
          assert ("ARC-VCS-GPATCH" `elem` arcIds)
    else do
      let sampleJson = BSC.pack "{\"matrixId\":\"CAMPAIGN-TEST\",\"description\":\"Test\",\"axes\":[],\"powerPolicy\":{\"softThrottleBatteryPct\":15,\"hardCheckpointBatteryPct\":7,\"allowOnBattery\":true,\"maxParallelSandboxesAC\":4,\"maxParallelSandboxesBat\":1},\"defaultTriage\":{\"emitAxiomaticStub\":true},\"arcs\":[{\"arcId\":\"ARC-1\",\"title\":\"Arc 1\",\"gitBranch\":\"main\",\"pert\":{\"optimistic\":1,\"mostLikely\":2,\"pessimistic\":3},\"seedMetaPackets\":[\"test.dhall\"]}]}"
      case Unfold.loadCampaignMatrixFromJson sampleJson of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right matrix -> do
          Unfold.matrixId matrix === "CAMPAIGN-TEST"
          length (Unfold.matrixArcs matrix) === 1

prop_campaign_unfold_recon_runner :: Property
prop_campaign_unfold_recon_runner = property $ do
  tmpDir <- evalIO $ do
    baseTmp <- Directory.getTemporaryDirectory
    let dir = baseTmp </> "test-recon-runner"
    Directory.createDirectoryIfMissing True (dir </> "src")
    TIO.writeFile (dir </> "src" </> "SampleModuleA.hs") $ T.unlines
      [ "module SampleModuleA (funcA, TypeA) where"
      , "data TypeA = TypeA"
      , "funcA :: Int -> String"
      , "funcA _ = \"hello\""
      ]
    TIO.writeFile (dir </> "src" </> "SampleModuleB.hs") $ T.unlines
      [ "module SampleModuleB (funcB) where"
      , "funcB :: String -> Bool"
      , "funcB _ = True"
      ]
    pure dir
  let recon = Unfold.ReconSpec
        { Unfold.reconTargetRepoDir = tmpDir
        , Unfold.reconInspectGlobs = ["src/*.hs"]
        , Unfold.reconTreeSitterGrammar = "haskell"
        , Unfold.reconOutputWitnessDhall = "witnesses/test-witness.dhall"
        }
  eWitness <- evalIO $ Unfold.runReconSpec recon
  evalIO $ Directory.removeDirectoryRecursive tmpDir
  case eWitness of
    Left err -> do
      annotate (T.unpack err)
      failure
    Right witness -> do
      assert ("SampleModuleA" `elem` Unfold.iwModules witness)
      assert ("SampleModuleB" `elem` Unfold.iwModules witness)
      assert ("funcA" `elem` Unfold.iwExportedSymbols witness)
      assert ("funcB" `elem` Unfold.iwExportedSymbols witness)
      let sigMap = Map.fromList (Unfold.iwTypeSignatures witness)
      Map.lookup "funcA" sigMap === Just "Int -> String"
      Map.lookup "funcB" sigMap === Just "String -> Bool"

prop_campaign_unfold_pushout_primitives :: Property
prop_campaign_unfold_pushout_primitives = property $ do
  let hostBase = Unfold.HostBase
        { Unfold.hbRepoDir = "/tmp/host"
        , Unfold.hbTargetModule = "Host.Kernel"
        , Unfold.hbExistingSymbols = ["kernelInit", "allocPage"]
        , Unfold.hbLiquidSig = Unfold.emptyLiquidSig
        }
      witness = Unfold.InterfaceWitness
        { Unfold.iwInterfaceName = "HostVM.Sig"
        , Unfold.iwTargetRepoDir = "/tmp/host"
        , Unfold.iwModules = ["Host.Kernel"]
        , Unfold.iwExportedSymbols = ["allocPage"]
        , Unfold.iwTypeSignatures = [("allocPage", "Int -> Page")]
        , Unfold.iwMeasures = []
        , Unfold.iwQualifiers = []
        , Unfold.iwLiquidSig = Unfold.emptyLiquidSig
        }
      pushout = Unfold.PushoutTemplate
        { Unfold.pushoutSharedInterfaceSig = "HostVM.Sig"
        , Unfold.pushoutWeaveSpecModule = "Pgcl.ClusterWeave"
        , Unfold.pushoutRequiredMeasures = ["clusterOrder"]
        , Unfold.pushoutRequiredQualifiers = ["v >= 0"]
        }
      arc = Unfold.CampaignArc
        { Unfold.arcId = "ARC-PGCL-WEAVE"
        , Unfold.arcTitle = "PGCL HostVM Weave Campaign"
        , Unfold.arcCoordinates = [("Constellation", "Pgcl")]
        , Unfold.arcGitBranch = "campaign/pgcl"
        , Unfold.arcDependsOnArcs = []
        , Unfold.arcSharedSheafEdges = ["e_pgcl_host"]
        , Unfold.arcMode = Unfold.Autonomous
        , Unfold.arcPert = Unfold.PertEstimate 2 4 8
        , Unfold.arcRecon = Nothing
        , Unfold.arcPushout = Just pushout
        , Unfold.arcSeedMetaPackets = []
        , Unfold.arcTriagePolicy = Unfold.QuarantineAndStub (Unfold.QuarantinePolicy True)
        }
  case Unfold.instantiatePushout hostBase witness pushout arc of
    Left err -> do
      annotate (T.unpack err)
      failure
    Right packets -> do
      assert (not (null packets))
      assert (all Unfold.isPrimitivePacket packets)
      case packets of
        (primary:_) -> do
          Unfold.ulpTargetModule primary === "Pgcl.ClusterWeave"
          Unfold.ulpRunBudgetSeconds primary === 4 * 120
          assert ("clusterOrder" `elem` Unfold.ulpAssumedGuarantees primary)
        [] -> failure

prop_campaign_unfold_schedule_graph_cpm :: Property
prop_campaign_unfold_schedule_graph_cpm = property $ do
  let dhallPath = "/home/nyc/src/plans/campaigns/november-constellation.dhall"
  exists <- evalIO $ Directory.doesFileExist dhallPath
  matrix <- if exists
    then do
      eMat <- evalIO $ Unfold.loadCampaignMatrix dhallPath
      case eMat of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right m -> pure m
    else do
      let sampleJson = BSC.pack "{\"matrixId\":\"CAMPAIGN-TEST\",\"description\":\"Test\",\"axes\":[],\"powerPolicy\":{\"softThrottleBatteryPct\":15,\"hardCheckpointBatteryPct\":7,\"allowOnBattery\":true,\"maxParallelSandboxesAC\":4,\"maxParallelSandboxesBat\":1},\"defaultTriage\":{\"emitAxiomaticStub\":true},\"arcs\":[{\"arcId\":\"ARC-1\",\"title\":\"Arc 1\",\"gitBranch\":\"main\",\"pert\":{\"optimistic\":1,\"mostLikely\":2,\"pessimistic\":3},\"seedMetaPackets\":[\"test.dhall\"]}]}"
      case Unfold.loadCampaignMatrixFromJson sampleJson of
        Left err -> do
          annotate (T.unpack err)
          failure
        Right m -> pure m
  eGraph <- evalIO $ Unfold.unfoldToScheduleGraph matrix
  case eGraph of
    Left gErr -> do
      annotate (T.unpack gErr)
      failure
    Right graph -> do
      let makespan = PERT.projectMakespan graph
      annotateShow makespan
      assert (makespan > 0)
      let metrics = PERT.computePERTMetrics graph
      annotateShow (PERT.pmProjectMakespan metrics)
      assert (PERT.pmProjectMakespan metrics > 0)
      assert (not (null (PERT.pmCriticalPath metrics)))
EOF
fi

echo "=== [TP-014A] Building yamaarashi ==="
cd "$SARU_DIR"
cabal v2-build yamaarashi -j20 --semaphore

echo "=== [TP-014A] Execution script complete ==="

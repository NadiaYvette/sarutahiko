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

import Control.Exception (SomeException, try)
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
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getHomeDirectory
  , listDirectory
  )
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import qualified Dhall.Import
import qualified Dhall.JSON

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

-- | Load and decode a Campaign Matrix directly from a Dhall manifest in-memory.
-- Uses the native Haskell Dhall library (Dhall.JSON.codeToValue) with zero subprocess overhead.
loadCampaignMatrix :: FilePath -> IO (Either Text CampaignMatrix)
loadCampaignMatrix path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("Dhall manifest not found: " <> T.pack path))
    else do
      content <- TIO.readFile path
      eVal <- try (Dhall.JSON.codeToValue Dhall.JSON.defaultConversion Dhall.JSON.ForbidWithinJSON Dhall.Import.RejectRemoteImports (Just path) content)
      case eVal of
        Right val ->
          case Aeson.fromJSON val of
            Aeson.Success matrix -> pure (Right matrix)
            Aeson.Error err      -> pure (Left ("Aeson decode error: " <> T.pack err))
        Left (e :: SomeException) ->
          pure (Left ("Dhall evaluation error: " <> T.pack (show e)))

-- | Load and decode a Campaign Matrix directly from JSON ByteString.
loadCampaignMatrixFromJson :: BS.ByteString -> Either Text CampaignMatrix
loadCampaignMatrixFromJson bs =
  case Aeson.eitherDecodeStrict' bs of
    Right matrix -> Right matrix
    Left err     -> Left ("Aeson decode error: " <> T.pack err)

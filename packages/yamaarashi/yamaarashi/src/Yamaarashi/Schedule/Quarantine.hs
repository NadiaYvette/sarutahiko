{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Yamaarashi.Schedule.Quarantine
-- Description : Cohomological Excision & Axiomatic Stub Generation for Triaged Tasks
--
-- When a task packet exhausts its maximum repair attempts, transitions its vertex
-- to 'TriagedHumanQuarantine' and records:
-- 1. Minimal Z3 counterexample model (M_cex)
-- 2. H^1 qualifier conflict classification
-- 3. Partial patch of applied edits so far
-- 4. An axiomatic stub module ('PrimAxiomaticStub') with @{-@ assume ... @-}@ Liquid
--    refinement type contracts and stub bodies returning
--    @error "AXIOMATIC_STUB: awaiting human triage on TP-014C"@.
--
-- Downstream dependent tasks can then compile, typecheck, discharge Z3 liquid subtyping
-- VCs, and run Synquid synthesis against the axiomatic stub in parallel, while end-to-end
-- runtime execution is blocked until human repair resolves the quarantined vertex.
module Yamaarashi.Schedule.Quarantine
  ( -- * 1. Quarantine Data Structures
    QuarantinedVertex (..)
  , QuarantineConfig (..)
  , defaultQuarantineConfig
    -- * 2. Triage Decision & Execution
  , shouldQuarantine
  , quarantineVertex
  , generateTriageReport
    -- * 3. Axiomatic Stub Synthesis
  , synthesizeAxiomaticStub
  , renderHaskellType
  , renderLiquidRefinement
  , renderLiquidPred
  , renderLiquidSort
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Gargamelle.Core.Institution.Liquid
  ( BinOp (..)
  , LiquidModel (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSort (..)
  , LiquidVal (..)
  , RBase (..)
  , RelOp (..)
  , RType (..)
  )
import Gargamelle.Sheaf.LatticeCohomology
  ( H1ConflictClassification (..)
  , H1QualifierConflict (..)
  , SheafVertexSpec (..)
  )

--------------------------------------------------------------------------------
-- 1. Quarantine Data Structures
--------------------------------------------------------------------------------

-- | Materialized record of a quarantined vertex awaiting human triage.
data QuarantinedVertex = QuarantinedVertex
  { qvVertexId          :: !Text
  -- ^ Quarantined task vertex ID (e.g., "TP-014C")
  , qvAttempts          :: !Int
  -- ^ Number of failed repair attempts exhausted
  , qvCounterexample    :: !(Maybe LiquidModel)
  -- ^ Minimal Z3 counterexample model M_cex
  , qvConflict          :: !(Maybe H1QualifierConflict)
  -- ^ H^1 qualifier conflict classification along failing sheaf boundary
  , qvPartialPatch      :: !Text
  -- ^ Partial .gpatch or diff of edits applied before triage
  , qvTriageReportPath  :: !FilePath
  -- ^ Path to the written triage report markdown file
  , qvAxiomaticStubCode :: !(Maybe Text)
  -- ^ Synthesized PrimAxiomaticStub code, if generated
  } deriving stock (Eq, Show, Generic)

-- | Configuration parameters controlling quarantine triage and stub synthesis.
data QuarantineConfig = QuarantineConfig
  { qcMaxRepairAttempts :: !Int
  -- ^ Threshold of repair attempts before triggering quarantine (e.g., 3 or 4)
  , qcEmitAxiomaticStub :: !Bool
  -- ^ Whether to synthesize a compileable PrimAxiomaticStub module
  , qcReportDir         :: !FilePath
  -- ^ Output directory for markdown triage reports
  , qcStubOutputDir     :: !FilePath
  -- ^ Output directory for synthesized Haskell/Liquid stub modules
  } deriving stock (Eq, Show, Generic)

-- | Default quarantine configuration.
defaultQuarantineConfig :: QuarantineConfig
defaultQuarantineConfig = QuarantineConfig
  { qcMaxRepairAttempts = 3
  , qcEmitAxiomaticStub = True
  , qcReportDir         = ".yamaarashi/quarantine/reports"
  , qcStubOutputDir     = "src"
  }

--------------------------------------------------------------------------------
-- 2. Triage Decision & Execution
--------------------------------------------------------------------------------

-- | Check whether a failing vertex has exhausted max repair attempts and must be quarantined.
shouldQuarantine :: QuarantineConfig -> Int -> Bool
shouldQuarantine cfg attempts = attempts >= qcMaxRepairAttempts cfg

-- | Transition a failing vertex into quarantine, generating reports and axiomatic stubs.
quarantineVertex
  :: QuarantineConfig
  -> Text                        -- ^ Vertex ID
  -> Int                         -- ^ Number of failed repair attempts
  -> Maybe LiquidModel           -- ^ Minimal Z3 counterexample model
  -> Maybe H1QualifierConflict   -- ^ H^1 qualifier conflict
  -> Text                        -- ^ Partial patch
  -> Maybe SheafVertexSpec       -- ^ Sheaf vertex specification (if available)
  -> IO QuarantinedVertex
quarantineVertex cfg vId attempts mCex mConflict partialPatch mSpec = do
  createDirectoryIfMissing True (qcReportDir cfg)
  let reportPath = qcReportDir cfg </> (T.unpack vId ++ "-triage-report.md")

  mStubCode <- if qcEmitAxiomaticStub cfg
    then case mSpec of
      Just spec -> do
        createDirectoryIfMissing True (qcStubOutputDir cfg)
        let stubCode = synthesizeAxiomaticStub vId spec
            stubPath = qcStubOutputDir cfg </> "PrimAxiomaticStub.hs"
        TIO.writeFile stubPath stubCode
        pure (Just stubCode)
      Nothing -> pure Nothing
    else pure Nothing

  let qv = QuarantinedVertex
        { qvVertexId          = vId
        , qvAttempts          = attempts
        , qvCounterexample    = mCex
        , qvConflict          = mConflict
        , qvPartialPatch      = partialPatch
        , qvTriageReportPath  = reportPath
        , qvAxiomaticStubCode = mStubCode
        }

  let reportText = generateTriageReport qv
  TIO.writeFile reportPath reportText
  pure qv

-- | Generate a comprehensive Markdown triage report for human review.
generateTriageReport :: QuarantinedVertex -> Text
generateTriageReport qv = T.unlines $
  [ "# Triaged Human Quarantine Report: " <> qvVertexId qv
  , ""
  , "- **Task Vertex ID:** " <> qvVertexId qv
  , "- **Exhausted Repair Attempts:** " <> T.pack (show (qvAttempts qv))
  , "- **Triage Report Path:** `" <> T.pack (qvTriageReportPath qv) <> "`"
  , "- **Axiomatic Stub Generated:** " <> (if maybe False (const True) (qvAxiomaticStubCode qv) then "Yes (`PrimAxiomaticStub.hs`)" else "No")
  , ""
  , "---"
  , ""
  , "## 1. Minimal Z3 Counterexample Model (M_cex)"
  , ""
  ] ++ renderCexSection (qvCounterexample qv) ++
  [ ""
  , "## 2. H^1 Qualifier Conflict Classification"
  , ""
  ] ++ renderConflictSection (qvConflict qv) ++
  [ ""
  , "## 3. Partial Patch Applied So Far"
  , ""
  , "```diff"
  , qvPartialPatch qv
  , "```"
  , ""
  , "## 4. Downstream Status"
  , ""
  , "Downstream dependent tasks have been unblocked via the synthesized `PrimAxiomaticStub` module."
  , "Verification and synthesis against the contract may proceed in parallel; runtime invocation is gated on human resolution."
  ]
  where
    renderCexSection = \case
      Nothing -> ["*No SMT counterexample model recorded.*"]
      Just model ->
        [ "| Variable | Valuation |"
        , "| :--- | :--- |"
        ] ++
        [ "| `" <> var <> "` | `" <> renderVal v <> "` |"
        | (var, v) <- Map.toList (modelVarEnv model)
        ]
      where
        renderVal = \case
          VInt i         -> T.pack (show i)
          VBool b        -> if b then "True" else "False"
          VSet xs        -> "{" <> T.intercalate ", " (map renderVal (Set.toList xs)) <> "}"
          VADT ctor args -> ctor <> "(" <> T.intercalate ", " (map renderVal args) <> ")"
          VRecord flds   -> "{" <> T.intercalate ", " [k <> ": " <> renderVal v | (k, v) <- Map.toList flds] <> "}"
          VVariant t v   -> t <> "(" <> renderVal v <> ")"

    renderConflictSection = \case
      Nothing -> ["*No H^1 cohomological obstruction recorded.*"]
      Just conflict ->
        [ "- **Failing Edge ID:** `" <> conflictEdgeId conflict <> "`"
        , "- **Source Vertex:** `" <> conflictSource conflict <> "`"
        , "- **Target Vertex:** `" <> conflictTarget conflict <> "`"
        , "- **Classification:** " <> renderClassification (conflictResolution conflict)
        , "- **Missing Qualifiers:**"
        ] ++
        [ "  * `" <> renderLiquidPred q <> "`"
        | q <- Set.toList (conflictMissingQuals conflict)
        ]
      where
        renderClassification = \case
          AutoRowRepairable field _ ->
            "AutoRowRepairable (field: `" <> field <> "`)"
          ArchitecturalContradiction preds ->
            "ArchitecturalContradiction (" <> T.pack (show (length preds)) <> " conflicting predicates)"

--------------------------------------------------------------------------------
-- 3. Axiomatic Stub Synthesis
--------------------------------------------------------------------------------

-- | Synthesize a compileable Haskell module 'PrimAxiomaticStub' from a 'SheafVertexSpec'.
--
-- The module:
-- 1. Enables @{-# LANGUAGE OverloadedStrings #-}@ and LiquidHaskell @{-@ LIQUID "--reflection" @-}@
-- 2. Exports all function signatures registered in the vertex typing environment 'sigEnv'.
-- 3. Attaches @{-@ assume <func> :: <RefinementType> @-}@ contracts.
-- 4. Synthesizes stub definitions:
--    @<func> = error "AXIOMATIC_STUB: awaiting human triage on <vertexId>"@.
synthesizeAxiomaticStub :: Text -> SheafVertexSpec -> Text
synthesizeAxiomaticStub vId spec =
  let sig = svSig spec
      env = sigEnv sig
      declarations = map (renderAxiomaticDecl vId) (Map.toList env)
  in T.unlines $
       [ "{-# LANGUAGE OverloadedStrings #-}"
       , "{-@ LIQUID \"--reflection\" @-}"
       , ""
       , "-- |"
       , "-- Module      : PrimAxiomaticStub"
       , "-- Description : Synthesized compileable axiomatic stub for quarantined vertex " <> vId
       , "--"
       , "-- Generated autonomously by Yamaarashi.Schedule.Quarantine (TP-014C)."
       , "-- Refinements are assumed axiomatically via {-@ assume @-} pragmas to allow downstream"
       , "-- dependent tasks to compile, discharge Z3 liquid subtyping VCs, and synthesize"
       , "-- code in parallel without blocking on human repair."
       , "module PrimAxiomaticStub where"
       , ""
       ] ++ declarations

-- | Render an assumed Liquid contract and Haskell function stub.
renderAxiomaticDecl :: Text -> (Text, RType) -> Text
renderAxiomaticDecl vId (funcName, rtype) =
  let liquidSig = renderLiquidRefinement rtype
      haskellSig = renderHaskellType rtype
      errMsg = "\"AXIOMATIC_STUB: awaiting human triage on " <> vId <> "\""
  in T.unlines
       [ "{-@ assume " <> funcName <> " :: " <> liquidSig <> " @-}"
       , funcName <> " :: " <> haskellSig
       , funcName <> " = error " <> errMsg
       , ""
       ]

-- | Render the unrefined Haskell type signature from an 'RType'.
renderHaskellType :: RType -> Text
renderHaskellType = \case
  RBScalar (RBase _ sort _) -> renderLiquidSort sort
  RArrow _ t1 t2 ->
    let l = wrapArrow t1 (renderHaskellType t1)
        r = renderHaskellType t2
    in l <> " -> " <> r
  REffect es base _ ->
    "Eff [" <> T.intercalate ", " es <> "] " <> renderLiquidSort (rSort base)
  where
    wrapArrow = \case
      RArrow {} -> \s -> "(" <> s <> ")"
      _         -> id

-- | Render the refined Liquid type signature from an 'RType'.
renderLiquidRefinement :: RType -> Text
renderLiquidRefinement = \case
  RBScalar (RBase v sort p) ->
    "{" <> v <> ":" <> renderLiquidSort sort <> " | " <> renderLiquidPred p <> "}"
  RArrow x t1 t2 ->
    let l = x <> ":" <> renderLiquidRefinement t1
        r = renderLiquidRefinement t2
    in l <> " -> " <> r
  REffect es base post ->
    "Eff [" <> T.intercalate ", " es <> "] {" <> rValueVar base <> ":" <> renderLiquidSort (rSort base) <> " | " <> renderLiquidPred post <> "}"

-- | Render a 'LiquidSort' to concrete Haskell/Liquid type syntax.
renderLiquidSort :: LiquidSort -> Text
renderLiquidSort = \case
  SortInt           -> "Int"
  SortBool          -> "Bool"
  SortSet s         -> "(Set.Set " <> renderLiquidSort s <> ")"
  SortVar v         -> v
  SortADT name args ->
    if null args
      then name
      else "(" <> name <> " " <> T.intercalate " " (map renderLiquidSort args) <> ")"
  SortRecordRow _   -> "Record"
  SortVariantRow _  -> "Variant"
  SortEffectRow _   -> "Effect"

-- | Render a 'LiquidPred' formula to concrete LiquidHaskell predicate syntax.
renderLiquidPred :: LiquidPred -> Text
renderLiquidPred = \case
  PTrue             -> "true"
  PFalse            -> "false"
  PVar v            -> v
  PIntLit n         -> T.pack (show n)
  PEmptySet s       -> "(Set.empty :: Set.Set " <> renderLiquidSort s <> ")"
  PMeasureApp m arg -> m <> "(" <> renderLiquidPred arg <> ")"
  PFieldProj f expr -> renderLiquidPred expr <> "." <> f
  PVariantTag tag e -> "is_" <> tag <> "(" <> renderLiquidPred e <> ")"
  PBinOp op a b     -> "(" <> renderLiquidPred a <> " " <> binOpStr op <> " " <> renderLiquidPred b <> ")"
  PRel op a b       -> "(" <> renderLiquidPred a <> " " <> relOpStr op <> " " <> renderLiquidPred b <> ")"
  PNot p            -> "not (" <> renderLiquidPred p <> ")"
  PAnd []           -> "true"
  PAnd ps           -> "(" <> T.intercalate " && " (map renderLiquidPred ps) <> ")"
  POr []            -> "false"
  POr ps            -> "(" <> T.intercalate " || " (map renderLiquidPred ps) <> ")"
  PImplies a b      -> "(" <> renderLiquidPred a <> " ==> " <> renderLiquidPred b <> ")"
  PIff a b          -> "(" <> renderLiquidPred a <> " <=> " <> renderLiquidPred b <> ")"
  PLiquidHole k vs  -> "?" <> k <> "(" <> T.intercalate ", " vs <> ")"
  where
    binOpStr = \case
      Add          -> "+"
      Sub          -> "-"
      Mul          -> "*"
      SetUnion     -> "Set.union"
      SetIntersect -> "Set.intersection"
      SetDiff      -> "Set.difference"

    relOpStr = \case
      Eq        -> "=="
      Neq       -> "/="
      Lt        -> "<"
      Le        -> "<="
      Gt        -> ">"
      Ge        -> ">="
      SetMember -> "Set.member"
      SetSubset -> "Set.isSubsetOf"

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Yamaarashi.Synthesis.Synquid
  ( -- * Synthesized Term AST
    SynTerm (..)
  , termToLiquidPred
    -- * Synthesis Environment, State, and Monad
  , Z3StreamSession (..)
  , SynEnv (..)
  , SynState (..)
  , SynM (..)
  , runSynM
    -- * Institutional Context Shifting
  , withSigMorphism
  , extVarMorphism
  , extPathMorphism
  , narrowVariantMorphism
    -- * Bidirectional Liquid Synthesis Entrypoints
  , synthesizeGoal
  , synthesizeScalarGoal
  , tryVariantExhaustion
  , synthesizeDirectTerm
  , synthesizeSpineApp
  , verifyGoalSubtype
  , synthesizeAbductiveBranch
  , synthesizeEffectful
    -- * Dependent Substitution Helpers
  , substVarInPred
  , substPredInRType
  , substPredInPred
  ) where

import Control.Applicative (Alternative (..))
import Control.Monad (MonadPlus (..), guard, msum)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Reader (MonadReader (..), ReaderT (..), asks)
import Control.Monad.State.Strict (MonadState (..), StateT (..), gets, modify')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import GHC.Generics (Generic)

import Gargamelle.Core.Institution.Liquid
  ( BinOp (..)
  , LiquidModel
  , LiquidPred (..)
  , LiquidSentence (..)
  , LiquidSig (..)
  , LiquidSigMorphism (..)
  , LiquidSort (..)
  , RBase (..)
  , RelOp (..)
  , RSchema (..)
  , RType (..)
  , SymName
  )
import Gargamelle.FOL.LiquidBridge
  ( SubtypeResult (..)
  , abductConditionZ3
  , checkLiquidSubtypingZ3
  )

--------------------------------------------------------------------------------
-- 1. Synthesized Program AST (Polymorphic over Polytropos & Penelope)
--------------------------------------------------------------------------------

data SynTerm
  = TVar SymName
  | TIntLit Integer
  | TBoolLit Bool
  | TLam SymName SynTerm
  | TApp SynTerm [SynTerm]
  -- ^ N-ary spine application: f e_1 ... e_n (used for Polytropos getF/setF/matchTagF)
  | TIf LiquidPred SynTerm SynTerm
  -- ^ Abducted branch: if P then C_t else C_f
  | TEffPure SynTerm
  -- ^ Pure return inside a Penelope effect row
  | TEffBind SymName SynTerm SynTerm
  -- ^ Penelope effectful bind: x <- perform_E arg; continuation
  deriving stock (Eq, Ord, Show, Generic)

-- | Projects pure scalar/measure-level SynTerms into LiquidPreds so dependent
-- arrow refinements (x:T1 -> T2) can substitute synthesized arguments directly.
termToLiquidPred :: SynTerm -> Maybe LiquidPred
termToLiquidPred = \case
  TVar v         -> Just (PVar v)
  TIntLit i      -> Just (PIntLit i)
  TBoolLit True  -> Just PTrue
  TBoolLit False -> Just PFalse
  TApp (TVar "add") [l, r] -> do
    pl <- termToLiquidPred l
    pr <- termToLiquidPred r
    Just (PBinOp Add pl pr)
  TApp (TVar "sub") [l, r] -> do
    pl <- termToLiquidPred l
    pr <- termToLiquidPred r
    Just (PBinOp Sub pl pr)
  TApp (TVar fn) [arg] -> do
    pArg <- termToLiquidPred arg
    if "getF_" `T.isPrefixOf` fn
      then Just (PMeasureApp ("sel_" <> T.drop 5 fn) pArg)
      else if "matchTagF_" `T.isPrefixOf` fn
        then Just (PMeasureApp ("vpayload_" <> T.drop 10 fn) pArg)
        else Just (PMeasureApp fn pArg)
  _ -> Nothing

--------------------------------------------------------------------------------
-- 2. Synthesis Environment, State, and Backtracking Monad
--------------------------------------------------------------------------------

-- | SMT Stream Session handle
data Z3StreamSession = Z3StreamSession
  deriving stock (Eq, Ord, Show, Generic)

data SynEnv = SynEnv
  { envSig        :: LiquidSig
  -- ^ Current LiquidInstitution signature at the active hole
  , envComponents :: Map SymName RSchema
  -- ^ Polytropos + Penelope + library combinator schemas
  , envZ3Session  :: Z3StreamSession
  -- ^ Persistent streaming Z3 session
  , envMaxDepth   :: Int
  -- ^ Remaining AST depth budget for E-term / I-term enumeration
  , envMaxAbduct  :: Int
  -- ^ Remaining branch-abduction depth budget
  , envStateVar   :: SymName
  -- ^ Active Penelope state variable symbol in scope
  , envFuelVar    :: SymName
  -- ^ Active Penelope resource fuel symbol in scope
  }

data SynState = SynState
  { stFreshCounter   :: !Int
  , stRejectedModels :: [LiquidModel]
  -- ^ Counterexample witnesses collected from Z3 refutations
  , stMorphTrace     :: [LiquidSigMorphism]
  -- ^ Audit trail of institutional signature morphisms along the current synthesis path
  } deriving stock (Show, Generic)

-- | Non-deterministic backtracking synthesis monad over IO with streaming Z3 state.
newtype SynM a = SynM
  { unSynM :: ReaderT SynEnv (StateT SynState IO) [a]
  }

instance Functor SynM where
  fmap f (SynM m) = SynM (fmap (map f) m)

instance Applicative SynM where
  pure x = SynM (pure [x])
  SynM mf <*> SynM mx = SynM $ do
    fs <- mf
    xs <- mx
    pure [f x | f <- fs, x <- xs]

instance Monad SynM where
  return = pure
  SynM m >>= k = SynM $ do
    xs <- m
    concat <$> mapM (unSynM . k) xs

instance Alternative SynM where
  empty = SynM (pure [])
  SynM a <|> SynM b = SynM $ do
    xs <- a
    if not (null xs)
      then pure xs
      else b

instance MonadPlus SynM where
  mzero = empty
  mplus = (<|>)

instance MonadIO SynM where
  liftIO io = SynM (fmap pure (liftIO io))

instance MonadReader SynEnv SynM where
  ask = SynM (fmap pure ask)
  local f (SynM m) = SynM (local f m)

instance MonadState SynState SynM where
  get = SynM (fmap pure get)
  put s = SynM (fmap pure (put s))

-- | Executes the synthesis monad, returning the first synthesized candidate (if any)
-- and final state.
runSynM :: SynEnv -> SynState -> SynM a -> IO (Maybe a, SynState)
runSynM env st (SynM m) = do
  (xs, st') <- runStateT (runReaderT m env) st
  pure (case xs of [] -> Nothing; (x:_) -> Just x, st')

freshSym :: SymName -> SynM SymName
freshSym prefix = do
  n <- gets stFreshCounter
  modify' $ \s -> s { stFreshCounter = n + 1 }
  pure (prefix <> "_" <> T.pack (show n))

--------------------------------------------------------------------------------
-- 3. Institutional Context Shifting via LiquidSigMorphism
--------------------------------------------------------------------------------

-- | Executes a sub-synthesis inside the target of a LiquidSigMorphism,
-- recording the morphism trace in state and updating envSig in reader.
withSigMorphism :: LiquidSigMorphism -> SynM a -> SynM a
withSigMorphism sigma action = do
  let target = morphTarget sigma
  modify' $ \s -> s { stMorphTrace = sigma : stMorphTrace s }
  local (\env -> env { envSig = target }) action

-- | Morphism extending Gamma with a new variable binding (x : T).
extVarMorphism :: SymName -> RType -> LiquidSig -> LiquidSigMorphism
extVarMorphism x rtype sig =
  let target = sig { sigEnv = Map.insert x rtype (sigEnv sig) }
      idVars = Map.fromSet id (Map.keysSet (sigEnv sig))
      idMeas = Map.fromSet id (Map.keysSet (sigMeasures sig))
  in LiquidSigMorphism
    { morphSource  = sig
    , morphTarget  = target
    , morphSortMap = Map.empty
    , morphVarMap  = idVars
    , morphMeasMap = idMeas
    }

-- | Morphism extending the path condition with an abducted branch guard P.
extPathMorphism :: LiquidPred -> LiquidSig -> LiquidSigMorphism
extPathMorphism guardPred sig =
  let target = sig { sigPathCond = guardPred : sigPathCond sig }
      idVars = Map.fromSet id (Map.keysSet (sigEnv sig))
      idMeas = Map.fromSet id (Map.keysSet (sigMeasures sig))
  in LiquidSigMorphism
    { morphSource  = sig
    , morphTarget  = target
    , morphSortMap = Map.empty
    , morphVarMap  = idVars
    , morphMeasMap = idMeas
    }

-- | Specialised Polytropos Morphism: When a negative branch proves
-- `NOT (Tag_l in vtags(u))`, automatically narrows `u`'s refinement in Gamma
-- by subtracting `Tag_l` from `vtags(u)` via `PBinOp SetDiff`.
narrowVariantMorphism :: LiquidPred -> LiquidSig -> LiquidSigMorphism
narrowVariantMorphism negGuard sig =
  case negGuard of
    PNot (PRel SetMember (PVar tagSym) (PMeasureApp "vtags" (PVar varU)))
      | "Tag_" `T.isPrefixOf` tagSym ->
        let narrowedFact =
              PRel Eq
                (PMeasureApp "vtags" (PVar varU))
                (PBinOp SetDiff (PMeasureApp "vtags" (PVar varU)) (PVar tagSym))
        in extPathMorphism (PAnd [negGuard, narrowedFact]) sig
    _ -> extPathMorphism negGuard sig

--------------------------------------------------------------------------------
-- 4. Top-Down Goal-Directed Synthesis (Checking Mode: Gamma |- ?? :: T)
--------------------------------------------------------------------------------

synthesizeGoal :: RType -> SynM SynTerm
synthesizeGoal = \case
  -- [Rule Arr-Intro]: Synthesize dependent function \x -> body
  RArrow x paramType retType -> do
    sig <- asks envSig
    let sigma = extVarMorphism x paramType sig
    body <- withSigMorphism sigma (synthesizeGoal retType)
    pure (TLam x body)
  -- [Rule Eff-Intro]: Synthesize Penelope effectful computation
  REffect effLabels preBase postPred ->
    synthesizeEffectful effLabels preBase postPred
  -- [Rule Scalar-Intro]: Synthesize refined scalar / Polytropos row value
  RBScalar goalBase ->
    synthesizeScalarGoal goalBase

-- | Synthesizes a term inhabiting a base refinement type `{ v : S | psi }`.
synthesizeScalarGoal :: RBase -> SynM SynTerm
synthesizeScalarGoal goalBase =
  -- 1. Static Variant Exhaustion Check:
  -- If any in-scope Polytropos VariantF has `vtags(u) == EmptySet` under the
  -- current path conditions, discharge the branch immediately via `absurdVariantF`.
  tryVariantExhaustion <|>
  -- 2. Direct Spine Enumeration (Variables, Literals, Polytropos/Library Applications)
  synthesizeDirectTerm goalBase <|>
  -- 3. Synquid Condition Abduction (`if P then C_t else C_f`)
  synthesizeAbductiveBranch goalBase

-- | Checks whether any VariantF binding in Gamma has had all its active tags
-- peeled off along the current path condition.
tryVariantExhaustion :: SynM SynTerm
tryVariantExhaustion = do
  sig <- asks envSig
  let variantBindings =
        [ u
        | (u, RBScalar (RBase _ (SortADT adtName _) _)) <- Map.toList (sigEnv sig)
        , "VariantF_" `T.isPrefixOf` adtName
        ]
  msum $ map (checkEmptyVariant sig) variantBindings
  where
    checkEmptyVariant sig u = do
      let sortTag = SortADT "PolytroposTag" []
          emptyVC = SenSubtype "v" sortTag PTrue $
            PRel Eq (PMeasureApp "vtags" (PVar u)) (PEmptySet sortTag)
      res <- liftIO $ checkLiquidSubtypingZ3 sig emptyVC
      case res of
        SubtypeValid -> pure (TApp (TVar "absurdVariantF") [TVar u])
        SubtypeRejected _ -> empty

--------------------------------------------------------------------------------
-- 5. Round-Trip Spine Synthesis (Inference + Subtyping Check)
--------------------------------------------------------------------------------

synthesizeDirectTerm :: RBase -> SynM SynTerm
synthesizeDirectTerm goalBase@RBase{..} = do
  depth <- asks envMaxDepth
  guard (depth >= 0)
  sig <- asks envSig
  comps <- asks envComponents
  -- Collect scalar variables in Gamma + polymorphic components
  let localCandidates =
        [ (x, RSchema [] ty) | (x, ty) <- Map.toList (sigEnv sig) ]
      compCandidates = Map.toList comps
      allCandidates = localCandidates ++ compCandidates
  msum
    [ do
        (term, inferredBase) <- synthesizeSpineApp name schema rSort
        verifyGoalSubtype inferredBase goalBase
        pure term
    | (name, schema) <- allCandidates
    ]

-- | Given a candidate head `f :: RSchema` and expected result sort `targetSort`,
-- instantiates `f`, synthesizes its arguments at `depth - 1`, substitutes the
-- synthesized arguments into the dependent return refinement, and yields the
-- resulting `SynTerm` paired with its inferred `RBase`.
synthesizeSpineApp
  :: SymName
  -> RSchema
  -> LiquidSort
  -> SynM (SynTerm, RBase)
synthesizeSpineApp headName (RSchema _tyVars rootType) targetSort = do
  (args, finalBase) <- go [] rootType
  guard (rSort finalBase == targetSort)
  let term = if null args then TVar headName else TApp (TVar headName) args
  pure (term, finalBase)
  where
    go :: [SynTerm] -> RType -> SynM ([SynTerm], RBase)
    go accArgs = \case
      RBScalar base -> do
        let selfPred = if null accArgs
              then PAnd [rRefine base, PRel Eq (PVar (rValueVar base)) (PVar headName)]
              else rRefine base
        pure (reverse accArgs, base { rRefine = selfPred })
      RArrow paramName paramType retType -> do
        depth <- asks envMaxDepth
        guard (depth > 0)
        argTerm <- local (\e -> e { envMaxDepth = depth - 1 }) $
          synthesizeGoal paramType
        let retType' = case termToLiquidPred argTerm of
              Just argPred -> substPredInRType paramName argPred retType
              Nothing      -> retType
        go (argTerm : accArgs) retType'
      REffect _ _ _ -> empty

-- | Discharges the Liquid Subtyping obligation:
-- Gamma, PathCond |- { v : S | phi_inferred } <: { v : S | psi_goal }
verifyGoalSubtype :: RBase -> RBase -> SynM ()
verifyGoalSubtype inferred goal = do
  sig <- asks envSig
  let v = rValueVar goal
      lhs = substVarInPred (rValueVar inferred) v (rRefine inferred)
      rhs = rRefine goal
      vc = SenSubtype v (rSort goal) lhs rhs
  res <- liftIO $ checkLiquidSubtypingZ3 sig vc
  case res of
    SubtypeValid -> pure ()
    SubtypeRejected cexModel -> do
      modify' $ \s -> s { stRejectedModels = cexModel : stRejectedModels s }
      empty

--------------------------------------------------------------------------------
-- 6. Synquid Condition Abduction (`if P then C_t else C_f`)
--------------------------------------------------------------------------------

synthesizeAbductiveBranch :: RBase -> SynM SynTerm
synthesizeAbductiveBranch goalBase = do
  abductBudget <- asks envMaxAbduct
  guard (abductBudget > 0)
  sig <- asks envSig
  -- 1. Synthesize a candidate `then` branch C_t under the weakened sort-only goal
  -- `{ v : rSort | PTrue }`, capturing its actual inferred refinement `inferredBase`.
  let localCandidates =
        [ (x, RSchema [] ty) | (x, ty) <- Map.toList (sigEnv sig) ]
  comps <- asks envComponents
  (thenTerm, inferredBase) <- msum
    [ synthesizeSpineApp name schema (rSort goalBase)
    | (name, schema) <- localCandidates ++ Map.toList comps
    ]
  -- 2. Formulate the Abduction Goal:
  -- Gamma /\ PathCond /\ P /\ phi_inferred(v) => psi_goal(v)
  let v = rValueVar goalBase
      inferredPred = substVarInPred (rValueVar inferredBase) v (rRefine inferredBase)
      abductionTarget = PImplies inferredPred (rRefine goalBase)
      scopeVars = Map.keys (sigEnv sig)
  maybeGuard <- liftIO $ abductConditionZ3 sig scopeVars abductionTarget
  abductedGuard <- case maybeGuard of
    Just g | g /= PTrue -> pure g
    _                   -> empty
  -- 3. Construct the Institutional Morphism for the False branch (`NOT P`),
  -- automatically injecting Polytropos variant tag narrowing if `P` is a tag check.
  let negGuard = PNot abductedGuard
      elseSigma = narrowVariantMorphism negGuard sig
  -- 4. Recursively synthesize the `else` branch C_f with decremented abduction budget
  elseTerm <- local (\e -> e { envMaxAbduct = abductBudget - 1 }) $
    withSigMorphism elseSigma (synthesizeScalarGoal goalBase)
  pure (TIf abductedGuard thenTerm elseTerm)

--------------------------------------------------------------------------------
-- 7. Penelope Effectful & Resource-Bounded Synthesis
--------------------------------------------------------------------------------

-- | Synthesizes a Penelope effectful computation satisfying pre-state, post-state,
-- effect row capability inclusion, and monotonically decreasing fuel budgets.
synthesizeEffectful
  :: [SymName]
  -> RBase
  -> LiquidPred
  -> SynM SynTerm
synthesizeEffectful allowedEffs preBase postGoal =
  tryEffectPure preBase postGoal <|>
  synthesizeEffectBind allowedEffs preBase postGoal

tryEffectPure :: RBase -> LiquidPred -> SynM SynTerm
tryEffectPure preBase postGoal = do
  let goalBase = preBase { rRefine = postGoal }
  verifyGoalSubtype preBase goalBase
  term <- synthesizeScalarGoal goalBase
  pure (TEffPure term)

synthesizeEffectBind
  :: [SymName]
  -> RBase
  -> LiquidPred
  -> SynM SynTerm
synthesizeEffectBind allowedEffs preBase postGoal = do
  depth <- asks envMaxDepth
  guard (depth > 0)
  sig     <- asks envSig
  stSym   <- asks envStateVar
  fuelSym <- asks envFuelVar

  msum
    [ do
        -- 1. Check that the effect's pre-condition & fuel budget (> 0) hold in current state
        let effPrePred = PMeasureApp ("eff_pre_" <> effLabel) (PVar stSym)
            fuelCheck  = PRel Ge (PVar fuelSym) (PIntLit 1)
            stepPreVC  = SenSubtype stSym (rSort preBase) (rRefine preBase) (PAnd [effPrePred, fuelCheck])
        res <- liftIO $ checkLiquidSubtypingZ3 sig stepPreVC
        case res of
          SubtypeRejected cex -> do
            modify' $ \s -> s { stRejectedModels = cex : stRejectedModels s }
            empty
          SubtypeValid -> pure ()

        -- 2. Advance Penelope state (st -> st_next) and decrement fuel (fuel_next == fuel - 1)
        nextStSym   <- freshSym "st"
        nextFuelSym <- freshSym "fuel"
        let postRelPred =
              PMeasureApp ("eff_post_" <> effLabel)
                (PMeasureApp "Pair" (PVar stSym))
            fuelStepPred =
              PRel Eq (PVar nextFuelSym) (PBinOp Sub (PVar fuelSym) (PIntLit 1))
            nextStBase = RBase "v" (rSort preBase) (PAnd [postRelPred, fuelStepPred])
            sigmaSt   = extVarMorphism nextStSym (RBScalar nextStBase) sig
            sigmaFuel = extVarMorphism nextFuelSym (RBScalar (RBase "v" SortInt fuelStepPred)) (morphTarget sigmaSt)
            sigmaPath = extPathMorphism (PAnd [postRelPred, fuelStepPred]) (morphTarget sigmaFuel)

        -- 3. Synthesize the continuation under updated state, fuel, and depth
        contTerm <- local
          (\e -> e
            { envMaxDepth = depth - 1
            , envStateVar = nextStSym
            , envFuelVar  = nextFuelSym
            })
          (withSigMorphism sigmaPath (synthesizeEffectful allowedEffs nextStBase postGoal))
        pure (TEffBind nextStSym (TApp (TVar ("perform_" <> effLabel)) [TVar stSym]) contTerm)
    | effLabel <- allowedEffs
    ]

--------------------------------------------------------------------------------
-- 8. Dependent Substitution Helpers
--------------------------------------------------------------------------------

substVarInPred :: SymName -> SymName -> LiquidPred -> LiquidPred
substVarInPred oldV newV = substPredInPred oldV (PVar newV)

substPredInRType :: SymName -> LiquidPred -> RType -> RType
substPredInRType var replacement = \case
  RBScalar (RBase v s p)
    | v == var  -> RBScalar (RBase v s p)
    | otherwise -> RBScalar (RBase v s (substPredInPred var replacement p))
  RArrow x t1 t2
    | x == var  -> RArrow x (substPredInRType var replacement t1) t2
    | otherwise -> RArrow x (substPredInRType var replacement t1) (substPredInRType var replacement t2)
  REffect es (RBase v s pre) post ->
    REffect
      es
      (RBase v s (substPredInPred var replacement pre))
      (substPredInPred var replacement post)

substPredInPred :: SymName -> LiquidPred -> LiquidPred -> LiquidPred
substPredInPred targetVar replacement = go
  where
    go = \case
      PVar v
        | v == targetVar -> replacement
        | otherwise      -> PVar v
      PEmptySet s      -> PEmptySet s
      PIntLit n        -> PIntLit n
      PTrue            -> PTrue
      PFalse           -> PFalse
      PMeasureApp m e  -> PMeasureApp m (go e)
      PFieldProj l e   -> PFieldProj l (go e)
      PVariantTag t e  -> PVariantTag t (go e)
      PBinOp op l r    -> PBinOp op (go l) (go r)
      PRel op l r      -> PRel op (go l) (go r)
      PNot e           -> PNot (go e)
      PAnd es          -> PAnd (map go es)
      POr es           -> POr (map go es)
      PImplies l r     -> PImplies (go l) (go r)
      PIff l r         -> PIff (go l) (go r)
      PLiquidHole h vs -> PLiquidHole h vs

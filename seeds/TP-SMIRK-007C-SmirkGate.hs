{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Yamaarashi.Synthesis.SmirkGate
Description : Synquid synthesis gate and benchmark for Smirk pipelines
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : Apache-2.0

Verifies automated deductive synthesis of Penelope (m,n,k,r)-ary regular expression
and glob pipelines from refinement-typed PortSig contracts using
Yamaarashi.Synthesis.Synquid.

-- Note [Smirk Pipeline Deductive Synthesis]
Instead of querying metered cloud LLMs for regex transformation pipelines,
Smirk pipelines are synthesized deductively from PortSig refinement contracts:
  - Input ports are represented as Liquid Base Types: {v : Text | pre(v)}
  - Output ports specify postconditions: {v : Text | post(v)}
  - State & Fuel counters enforce step-bounded termination

The ConcurrentZ3Pool discharges subtyping verification conditions and abducts
branching guards, ensuring generated code is guaranteed free of ReDoS vulnerabilities
and catastrophic backtracking by construction.
-}
module Yamaarashi.Synthesis.SmirkGate
  ( -- * Port Contracts
    PortContract (..)
  , defaultSmirkContract

    -- * Pipeline Synthesis
  , synthesizeSmirkPipeline

    -- * Benchmark & Verification Gate
  , BenchmarkResult (..)
  , runSmirkSynthesisBenchmark
  , benchMain
  ) where

import Control.Monad.IO.Class (MonadIO (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.CPUTime (getCPUTime)

import Gargamelle.Core.Institution.Liquid
  ( BinOp (..)
  , LiquidPred (..)
  , LiquidSig (..)
  , LiquidSort (..)
  , MeasureDecl (..)
  , RBase (..)
  , RelOp (..)
  , RSchema (..)
  , RType (..)
  )
import Yamaarashi.Synthesis.Synquid
  ( SynEnv (..)
  , SynM
  , SynState (..)
  , SynTerm (..)
  , Z3StreamSession (..)
  , runSynM
  , synthesizeDirectTerm
  )

-- | Refinement-typed PortSig contract for a streaming regex pipeline stage.
data PortContract = PortContract
  { pcName     :: !Text
  , pcInput    :: !LiquidSort
  , pcOutput   :: !LiquidSort
  , pcPreCond  :: !LiquidPred
  , pcPostCond :: !LiquidPred
  } deriving stock (Eq, Show, Generic)

-- | Benchmark performance and verification results.
data BenchmarkResult = BenchmarkResult
  { brContractName   :: !Text
  , brSuccess        :: !Bool
  , brSynthesizedAST :: !(Maybe SynTerm)
  , brElapsedMicros  :: !Integer
  } deriving stock (Eq, Show, Generic)

-- | Default contract: Evacuable non-empty split step with fuel decrease.
defaultSmirkContract :: PortContract
defaultSmirkContract = PortContract
  { pcName     = "smirkNonEmptySplit"
  , pcInput    = SortADT "Text" []
  , pcOutput   = SortADT "Text" []
  , pcPreCond  = PRel Ge (PMeasureApp "length" (PVar "v")) (PIntLit 1)
  , pcPostCond = PRel Lt (PMeasureApp "length" (PVar "v")) (PMeasureApp "length" (PVar "v_in"))
  }

-- | Synthesize a Penelope pipeline step from a PortSig contract without metered LLMs.
synthesizeSmirkPipeline :: PortContract -> IO (Either Text SynTerm)
synthesizeSmirkPipeline PortContract{..} = do
  let sortText = SortADT "Text" []
      measures = Map.fromList
        [ ("length", MeasureDecl "length" sortText SortInt True)
        ]
      sig = LiquidSig
        { sigSorts      = Set.fromList ["Text", "Int", "Bool"]
        , sigMeasures   = measures
        , sigCtorAxioms = []
        , sigQualifiers = Set.empty
        , sigEnv        = Map.fromList
            [ ("v_in", RBScalar (RBase "v" pcInput pcPreCond))
            , ("v",    RBScalar (RBase "v" sortText PTrue))
            , ("tail", RBScalar (RBase "tail" sortText PTrue))
            ]
        , sigPathCond   = [pcPreCond]
        }
      env = SynEnv
        { envSig        = sig
        , envComponents = Map.fromList
            [ ("tail", RSchema [] (RBScalar (RBase "v" sortText pcPostCond)))
            ]
        , envZ3Session  = Z3StreamSession
        , envMaxDepth   = 4
        , envMaxAbduct  = 2
        , envStateVar   = "st"
        , envFuelVar    = "fuel"
        }
      st = SynState
        { stFreshCounter   = 0
        , stRejectedModels = []
        , stMorphTrace     = []
        }
      goalBase = RBase "v" pcOutput pcPostCond

  (mTerm, _) <- runSynM env st (synthesizeDirectTerm goalBase :: SynM SynTerm)
  case mTerm of
    Just term -> pure (Right term)
    Nothing   -> pure (Left "Synthesis exhausted candidate search space without satisfying contract")

-- | Execute the synthesis gate benchmark suite across test contracts.
runSmirkSynthesisBenchmark :: IO BenchmarkResult
runSmirkSynthesisBenchmark = do
  t0 <- getCPUTime
  res <- synthesizeSmirkPipeline defaultSmirkContract
  t1 <- getCPUTime
  let elapsed = (t1 - t0) `div` 1000000 -- Convert picoseconds to microseconds
  case res of
    Right term -> pure BenchmarkResult
      { brContractName   = pcName defaultSmirkContract
      , brSuccess        = True
      , brSynthesizedAST = Just term
      , brElapsedMicros  = elapsed
      }
    Left _ -> pure BenchmarkResult
      { brContractName   = pcName defaultSmirkContract
      , brSuccess        = False
      , brSynthesizedAST = Nothing
      , brElapsedMicros  = elapsed
      }

-- | CLI entrypoint for yamaarashi-smirk-synth-bench executable.
benchMain :: IO ()
benchMain = do
  TIO.putStrLn "=== [Yamaarashi Smirk Synthesis Gate Benchmark] ==="
  res <- runSmirkSynthesisBenchmark
  TIO.putStrLn $ "Contract: " <> brContractName res
  TIO.putStrLn $ "Success:  " <> (if brSuccess res then "YES" else "NO")
  TIO.putStrLn $ "Latency:  " <> T.pack (show (brElapsedMicros res)) <> " µs"
  case brSynthesizedAST res of
    Just ast -> TIO.putStrLn $ "Term:     " <> T.pack (show ast)
    Nothing  -> TIO.putStrLn "Term:     FAILED"
  TIO.putStrLn "=== [Benchmark Complete] ==="

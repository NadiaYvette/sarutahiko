{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef (newIORef)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Text.Printf (printf)

import Effectful
import qualified Polysemy as P

import Spike

-- | Run 10^6 operations and evaluate dynamic dispatch overhead
main :: IO ()
main = do
  let iterations = 1000000 :: Int
  putStrLn "=================================================================="
  putStrLn "  Handlers-as-Records Empirical Spike Benchmark"
  putStrLn "  Evaluating dynamic dispatch latency across 1,000,000 operations"
  putStrLn "  Quality Gate: Dynamic dispatch latency overhead <= 5.0%"
  putStrLn "=================================================================="

  -- -------------------------------------------------------------------------
  -- Effectful Benchmark
  -- -------------------------------------------------------------------------
  putStrLn "\n--- [Effectful Runtime Benchmark] ---"

  refDirectEff <- newIORef Map.empty
  t0DirectEff <- getCurrentTime
  runEff . runKeyValueDirectEffectful refDirectEff $ runWorkloadEffectful iterations
  t1DirectEff <- getCurrentTime
  let durDirectEff = realToFrac (diffUTCTime t1DirectEff t0DirectEff) :: Double
  printf "  Direct Pattern-Matching : %8.4f s (%8.2f ns/op)\n" durDirectEff (durDirectEff / fromIntegral iterations * 1e9)

  refRecordEff <- newIORef Map.empty
  t0RecordEff <- getCurrentTime
  runEff . runKeyValueRecordEffectful (mkKeyValueRecordEffectful refRecordEff) $ runWorkloadEffectful iterations
  t1RecordEff <- getCurrentTime
  let durRecordEff = realToFrac (diffUTCTime t1RecordEff t0RecordEff) :: Double
  printf "  Handlers-as-Records     : %8.4f s (%8.2f ns/op)\n" durRecordEff (durRecordEff / fromIntegral iterations * 1e9)

  let overheadEff = ((durRecordEff - durDirectEff) / durDirectEff) * 100.0
  printf "  Effectful Overhead      : %8.2f %%\n" overheadEff

  -- -------------------------------------------------------------------------
  -- Polysemy Benchmark
  -- -------------------------------------------------------------------------
  putStrLn "\n--- [Polysemy Runtime Benchmark] ---"

  refDirectPoly <- newIORef Map.empty
  t0DirectPoly <- getCurrentTime
  P.runM . runKeyValueDirectPolysemy refDirectPoly $ runWorkloadPolysemy iterations
  t1DirectPoly <- getCurrentTime
  let durDirectPoly = realToFrac (diffUTCTime t1DirectPoly t0DirectPoly) :: Double
  printf "  Direct Pattern-Matching : %8.4f s (%8.2f ns/op)\n" durDirectPoly (durDirectPoly / fromIntegral iterations * 1e9)

  refRecordPoly <- newIORef Map.empty
  t0RecordPoly <- getCurrentTime
  P.runM . runKeyValueRecordPolysemy (mkKeyValueRecordPolysemy refRecordPoly) $ runWorkloadPolysemy iterations
  t1RecordPoly <- getCurrentTime
  let durRecordPoly = realToFrac (diffUTCTime t1RecordPoly t0RecordPoly) :: Double
  printf "  Handlers-as-Records     : %8.4f s (%8.2f ns/op)\n" durRecordPoly (durRecordPoly / fromIntegral iterations * 1e9)

  let overheadPoly = ((durRecordPoly - durDirectPoly) / durDirectPoly) * 100.0
  printf "  Polysemy Overhead       : %8.2f %%\n" overheadPoly

  -- -------------------------------------------------------------------------
  -- Adjudication
  -- -------------------------------------------------------------------------
  putStrLn "\n=================================================================="
  putStrLn "  Spike Adjudication Summary"
  putStrLn "=================================================================="
  printf "  Effectful Dispatch Overhead: %6.2f %%\n" overheadEff
  printf "  Polysemy  Dispatch Overhead: %6.2f %%\n" overheadPoly

  if overheadEff <= 5.0 && overheadPoly <= 5.0
    then do
      putStrLn "\n  [DECISION: PASS - BRANCH A]"
      putStrLn "  Dynamic dispatch overhead is <= 5.0% across both effect systems."
      putStrLn "  Handlers-as-records may be adopted program-wide."
    else do
      putStrLn "\n  [DECISION: FALLBACK - BRANCH B]"
      putStrLn "  Dynamic dispatch overhead exceeds the 5.0% performance gate (or higher-order seam resistance)."
      putStrLn "  Adopting standard handwritten dual-interpreter bridges (runEffectful / runPolysemy)."
  putStrLn "=================================================================="

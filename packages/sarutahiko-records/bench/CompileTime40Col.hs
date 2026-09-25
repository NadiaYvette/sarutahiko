{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

module Main (main) where

import Data.Functor.Identity (Identity (..))
import qualified Data.Record.Anon.Advanced as Anon
import Data.Time.Clock (diffUTCTime, getCurrentTime)

import Sarutahiko.Records.Combinators (emptyRecord, getRecordField)

-- | 40-column record benchmark testing large-anon compilation and access scaling.
main :: IO ()
main = do
  putStrLn "=== Compiling and Evaluating 40-Column Record Benchmark ==="
  t0 <- getCurrentTime
  let r0 = emptyRecord
      r1  = Anon.insert #c01 (Identity (1 :: Int)) r0
      r2  = Anon.insert #c02 (Identity (2 :: Int)) r1
      r3  = Anon.insert #c03 (Identity (3 :: Int)) r2
      r4  = Anon.insert #c04 (Identity (4 :: Int)) r3
      r5  = Anon.insert #c05 (Identity (5 :: Int)) r4
      r6  = Anon.insert #c06 (Identity (6 :: Int)) r5
      r7  = Anon.insert #c07 (Identity (7 :: Int)) r6
      r8  = Anon.insert #c08 (Identity (8 :: Int)) r7
      r9  = Anon.insert #c09 (Identity (9 :: Int)) r8
      r10 = Anon.insert #c10 (Identity (10 :: Int)) r9
      r11 = Anon.insert #c11 (Identity (11 :: Int)) r10
      r12 = Anon.insert #c12 (Identity (12 :: Int)) r11
      r13 = Anon.insert #c13 (Identity (13 :: Int)) r12
      r14 = Anon.insert #c14 (Identity (14 :: Int)) r13
      r15 = Anon.insert #c15 (Identity (15 :: Int)) r14
      r16 = Anon.insert #c16 (Identity (16 :: Int)) r15
      r17 = Anon.insert #c17 (Identity (17 :: Int)) r16
      r18 = Anon.insert #c18 (Identity (18 :: Int)) r17
      r19 = Anon.insert #c19 (Identity (19 :: Int)) r18
      r20 = Anon.insert #c20 (Identity (20 :: Int)) r19
      r21 = Anon.insert #c21 (Identity (21 :: Int)) r20
      r22 = Anon.insert #c22 (Identity (22 :: Int)) r21
      r23 = Anon.insert #c23 (Identity (23 :: Int)) r22
      r24 = Anon.insert #c24 (Identity (24 :: Int)) r23
      r25 = Anon.insert #c25 (Identity (25 :: Int)) r24
      r26 = Anon.insert #c26 (Identity (26 :: Int)) r25
      r27 = Anon.insert #c27 (Identity (27 :: Int)) r26
      r28 = Anon.insert #c28 (Identity (28 :: Int)) r27
      r29 = Anon.insert #c29 (Identity (29 :: Int)) r28
      r30 = Anon.insert #c30 (Identity (30 :: Int)) r29
      r31 = Anon.insert #c31 (Identity (31 :: Int)) r30
      r32 = Anon.insert #c32 (Identity (32 :: Int)) r31
      r33 = Anon.insert #c33 (Identity (33 :: Int)) r32
      r34 = Anon.insert #c34 (Identity (34 :: Int)) r33
      r35 = Anon.insert #c35 (Identity (35 :: Int)) r34
      r36 = Anon.insert #c36 (Identity (36 :: Int)) r35
      r37 = Anon.insert #c37 (Identity (37 :: Int)) r36
      r38 = Anon.insert #c38 (Identity (38 :: Int)) r37
      r39 = Anon.insert #c39 (Identity (39 :: Int)) r38
      r40 = Anon.insert #c40 (Identity (40 :: Int)) r39

  let val1  = runIdentity (getRecordField #c01 r40)
      val20 = runIdentity (getRecordField #c20 r40)
      val40 = runIdentity (getRecordField #c40 r40)
      total = val1 + val20 + val40
  t1 <- getCurrentTime
  let elapsed = diffUTCTime t1 t0
  putStrLn $ "Constructed and queried 40-col record (total = " ++ show total ++ ") in " ++ show elapsed
  putStrLn "[PASS] CompileTime40Col benchmark completed successfully."

{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BSC
import Data.IORef
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hedgehog
import Test.Tasty
import Test.Tasty.Hedgehog
import Yamaarashi.Flow

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Yamaarashi Flow Scheduler"
  [ testProperty "Mid-run resumption: pre-cached A & B skipped, only C runs" prop_resumption
  , testProperty "Early cutoff: identical output hash prunes downstream nodes" prop_early_cutoff
  , testProperty "Dependency change: changed output forces downstream re-execution" prop_dependency_change
  , testProperty "Cycle detection: cyclic graph rejected before execution" prop_cycle_detection
  ]

-- | 3-step pipeline: nodeA -> nodeB -> nodeC
nodeA, nodeB, nodeC :: TaskNode
nodeA = TaskNode (TaskId "nodeA") "Step A" Deterministic Set.empty (Just (VFSLocation "$_/stepA"))
nodeB = TaskNode (TaskId "nodeB") "Step B" Deterministic (Set.singleton (TaskId "nodeA")) (Just (VFSLocation "$_/stepB"))
nodeC = TaskNode (TaskId "nodeC") "Step C" Deterministic (Set.singleton (TaskId "nodeB")) (Just (VFSLocation "$_/stepC"))

pipelineGraph :: TaskGraph
pipelineGraph = buildGraph [nodeA, nodeB, nodeC]

prop_resumption :: Property
prop_resumption = property $ do
  -- Track which nodes actually ran
  executedNodesRef <- evalIO $ newIORef ([] :: [TaskId])

  -- Initial store simulating a run interrupted after nodeB
  let initialStore = SchedulerStore $ Map.fromList
        [ ( TaskId "nodeA"
          , TaskResultRecord Executed "hashA" "outputA"
          )
        , ( TaskId "nodeB"
          , TaskResultRecord Executed "hashB" "outputB"
          )
        ]

      runner node = do
        modifyIORef executedNodesRef (nodeId node :)
        pure ("output_" <> BSC.pack (show (nodeId node)), "hash_" <> BSC.pack (show (nodeId node)))

  eResult <- evalIO $ runTaskGraph runner pipelineGraph initialStore
  case eResult of
    Left err -> do
      annotateShow err
      failure
    Right (results, finalStore) -> do
      executedNodes <- evalIO $ readIORef executedNodesRef

      -- Only nodeC should have been executed!
      executedNodes === [TaskId "nodeC"]

      -- nodeA and nodeB were skipped; nodeC was executed
      (resultStatus <$> Map.lookup (TaskId "nodeA") results) === Just Skipped
      (resultStatus <$> Map.lookup (TaskId "nodeB") results) === Just Skipped
      (resultStatus <$> Map.lookup (TaskId "nodeC") results) === Just Executed

      -- Final store contains all three nodes
      Map.member (TaskId "nodeA") (unStore finalStore) === True
      Map.member (TaskId "nodeB") (unStore finalStore) === True
      Map.member (TaskId "nodeC") (unStore finalStore) === True

prop_early_cutoff :: Property
prop_early_cutoff = property $ do
  -- First run: all 3 nodes execute
  executed1Ref <- evalIO $ newIORef ([] :: [TaskId])
  let runner1 node = do
        modifyIORef executed1Ref (nodeId node :)
        pure ("payload_" <> BSC.pack (show (nodeId node)), "hash_" <> BSC.pack (show (nodeId node)))

  eResult1 <- evalIO $ runTaskGraph runner1 pipelineGraph emptyStore
  case eResult1 of
    Left err -> do
      annotateShow err
      failure
    Right (results1, store1) -> do
      executed1 <- evalIO $ readIORef executed1Ref
      length executed1 === 3
      (resultStatus <$> Map.lookup (TaskId "nodeA") results1) === Just Executed
      (resultStatus <$> Map.lookup (TaskId "nodeB") results1) === Just Executed
      (resultStatus <$> Map.lookup (TaskId "nodeC") results1) === Just Executed

      -- Second run: nodeA is externally dirtied, but yields IDENTICAL hash!
      executed2Ref <- evalIO $ newIORef ([] :: [TaskId])
      let isDirtyA node = nodeId node == TaskId "nodeA"
          runner2 node = do
            modifyIORef executed2Ref (nodeId node :)
            -- Produces the same hash as run 1!
            pure ("payload_" <> BSC.pack (show (nodeId node)), "hash_" <> BSC.pack (show (nodeId node)))

      eResult2 <- evalIO $ runTaskGraphEx isDirtyA runner2 pipelineGraph store1
      case eResult2 of
        Left err2 -> do
          annotateShow err2
          failure
        Right (results2, _) -> do
          executed2 <- evalIO $ readIORef executed2Ref

          -- Only nodeA executed! nodeB and nodeC were pruned by early cutoff!
          executed2 === [TaskId "nodeA"]
          (resultStatus <$> Map.lookup (TaskId "nodeA") results2) === Just Executed
          (resultStatus <$> Map.lookup (TaskId "nodeB") results2) === Just Skipped
          (resultStatus <$> Map.lookup (TaskId "nodeC") results2) === Just Skipped

prop_dependency_change :: Property
prop_dependency_change = property $ do
  -- Run 1: establish baseline
  let runner1 node = pure ("payload_" <> BSC.pack (show (nodeId node)), "hash_" <> BSC.pack (show (nodeId node)))
  Right (_, store1) <- evalIO $ runTaskGraph runner1 pipelineGraph emptyStore

  -- Run 2: nodeA is dirtied and produces a DIFFERENT hash, causing nodeB to also produce a different hash
  executedRef <- evalIO $ newIORef ([] :: [TaskId])
  let isDirtyA node = nodeId node == TaskId "nodeA"
      runner2 node = do
        modifyIORef executedRef (nodeId node :)
        pure ("new_payload_" <> BSC.pack (show (nodeId node)), "new_hash_" <> BSC.pack (show (nodeId node)))

  Right (results2, _) <- evalIO $ runTaskGraphEx isDirtyA runner2 pipelineGraph store1
  executed <- evalIO $ readIORef executedRef

  -- All 3 nodes had to re-execute because outputs cascaded
  length executed === 3
  (resultStatus <$> Map.lookup (TaskId "nodeA") results2) === Just Executed
  (resultStatus <$> Map.lookup (TaskId "nodeB") results2) === Just Executed
  (resultStatus <$> Map.lookup (TaskId "nodeC") results2) === Just Executed

prop_cycle_detection :: Property
prop_cycle_detection = property $ do
  let cyclicA = TaskNode (TaskId "cA") "cA" Deterministic (Set.singleton (TaskId "cB")) Nothing
      cyclicB = TaskNode (TaskId "cB") "cB" Deterministic (Set.singleton (TaskId "cA")) Nothing
      cyclicGraph = buildGraph [cyclicA, cyclicB]

  eResult <- evalIO $ runTaskGraph (\_ -> pure ("x", "h")) cyclicGraph emptyStore
  case eResult of
    Left err -> err === "Cycle detected in task graph"
    Right _  -> failure

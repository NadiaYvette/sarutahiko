{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Set as Set
import qualified Data.Text as T
import Hedgehog
import Test.Tasty
import Test.Tasty.Hedgehog
import Sarutahiko.Effect.TaskQueue (TaskId (..))
import Yamaarashi.Spec

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Yamaarashi Spec & VirtualTree"
  [ testProperty "VirtualTree extraction: union over all conditional branches" prop_virtual_tree_overapproximation
  , testProperty "Task subdivision: decomposes complex tree into primitive leaves" prop_subdivide_primitives
  , testProperty "YAML rendering: matches task packet structure" prop_render_task_packet_yaml
  ]

res1, res2, res3, res4 :: ResourceDescriptor
res1 = GitWorktreeResource "/tmp/wt1" "main"
res2 = CompilerToolchain "ghc-9.12.2"
res3 = SandboxPolicy "bwrap-isolated"
res4 = ComputeBudget 300

sampleSpecTree :: SpecNode
sampleSpecTree =
  SequentialSpecs
    [ AtomicSpec (TaskId "init") "Initialize worktree" [res1] (Just "git status")
    , ConditionalSpec
        "isReleaseBuild"
        (AtomicSpec (TaskId "build-opt") "Optimized build" [res2, res3] (Just "cabal build -O2"))
        (AtomicSpec (TaskId "build-fast") "Fast build" [res2, res4] (Just "cabal build -O0"))
    , ParallelSpecs
        [ AtomicSpec (TaskId "test-unit") "Unit tests" [res3] (Just "cabal test")
        , AtomicSpec (TaskId "lint") "Linting" [res4] (Just "hlint .")
        ]
    ]

prop_virtual_tree_overapproximation :: Property
prop_virtual_tree_overapproximation = property $ do
  let vtree = extractVirtualTree sampleSpecTree
      expectedResources = Set.fromList [res1, res2, res3, res4]
  virtualResources vtree === expectedResources

prop_subdivide_primitives :: Property
prop_subdivide_primitives = property $ do
  let leaves = subdivideSpec sampleSpecTree
  -- There should be 5 atomic tasks (init, build-opt, build-fast, test-unit, lint)
  length leaves === 5
  let ids = map atomicId leaves
  ids === [TaskId "init", TaskId "build-opt", TaskId "build-fast", TaskId "test-unit", TaskId "lint"]
  -- Every leaf must be primitive
  assert $ all (\t -> isPrimitive (AtomicSpec (atomicId t) (atomicDescription t) (atomicResources t) (atomicVerify t))) leaves

prop_render_task_packet_yaml :: Property
prop_render_task_packet_yaml = property $ do
  let taskItem = AtomicTask
        { atomicId = TaskId "fix-lexer"
        , atomicTitle = "Fix kogaki wire lexer"
        , atomicDescription = "Ensure lexer handles nonempty correctly"
        , atomicResources = [res1, res2]
        , atomicVerify = Just "cabal test"
        }
      rendered = renderTaskPacketYaml taskItem

  assert $ "id: fix-lexer" `T.isInfixOf` rendered
  assert $ "title: Fix kogaki wire lexer" `T.isInfixOf` rendered
  assert $ "dependencies: []" `T.isInfixOf` rendered
  assert $ "packages: []" `T.isInfixOf` rendered
  assert $ "success_criteria:" `T.isInfixOf` rendered
  assert $ "- cabal test" `T.isInfixOf` rendered

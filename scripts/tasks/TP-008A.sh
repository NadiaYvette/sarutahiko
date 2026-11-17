#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-008A] Deploying Sarutahiko.Hashigakari.Store ==="

# 0. Ensure cabal.project.local has pukinos packages
if [ ! -f cabal.project.local ] && [ -f /home/nyc/src/sarutahiko/cabal.project.local ]; then
  cp -f /home/nyc/src/sarutahiko/cabal.project.local ./cabal.project.local
fi

mkdir -p packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari

# 1. Mount pre-staged seed
cp -f /home/nyc/src/plans/seeds/TP-008A-HashigakariStore.hs packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/Store.hs

# 2. Expose module and add dependencies in hashigakari-core.cabal
python3 -c '
with open("packages/hashigakari/hashigakari-core/hashigakari-core.cabal", "r") as f:
    content = f.read()

if "Sarutahiko.Hashigakari.Store" not in content:
    content = content.replace("        Hashigakari.Core.Patch\n", "        Hashigakari.Core.Patch\n        Sarutahiko.Hashigakari.Store\n")

if "pukinos-core" not in content:
    content = content.replace("        sarutahiko-effect-signatures >= 0.1\n", "        sarutahiko-effect-signatures >= 0.1,\n        pukinos-core,\n        pukinos-penelope\n")
    content = content.replace("        tasty-hedgehog\n", "        tasty-hedgehog,\n        pukinos-core,\n        pukinos-penelope\n")

with open("packages/hashigakari/hashigakari-core/hashigakari-core.cabal", "w") as f:
    f.write(content)
'

# 3. Add test to packages/hashigakari/hashigakari-core/test/Spec.hs
python3 -c '
with open("packages/hashigakari/hashigakari-core/test/Spec.hs", "r") as f:
    content = f.read()

if "Sarutahiko.Hashigakari.Store" not in content:
    content = content.replace("import Hashigakari.Core\n", "import Hashigakari.Core\nimport Sarutahiko.Hashigakari.Store\n")

if "prop_store_merkle_commit" not in content:
    content = content.replace("  [ testProperty \"AST construction and composition\" prop_ast_composition\n", "  [ testProperty \"HashigakariStore Merkle region commit and MVCC lookup\" prop_store_merkle_commit\n  , testProperty \"AST construction and composition\" prop_ast_composition\n")
    test_code = """
prop_store_merkle_commit :: Property
prop_store_merkle_commit = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  payload <- forAll $ Gen.text (Range.linear 1 50) Gen.alpha
  let node1Id = computeMerkleDbId "Haskell" payload []
      node1 = HyperNode node1Id name "Haskell" [] 42 payload
      store0 = emptyHashigakariStore
      (rootId, store1) = commitMerkleRegion True [node1] store0
      snap = checkoutMVCCSnapshot store1
  rootId === node1Id
  lookupNodeById node1Id snap === Just node1
"""
    content = content.rstrip() + "\n" + test_code

with open("packages/hashigakari/hashigakari-core/test/Spec.hs", "w") as f:
    f.write(content)
'

echo "=== [TP-008A] Building and testing ==="
cabal v2-build hashigakari-core -j20 --semaphore
cabal v2-test hashigakari-core

echo "=== [TP-008A] Script execution complete ==="

#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-008C] Deploying Sarutahiko.Hashigakari.EditConeLSP ==="

# 0. Ensure cabal.project.local has pukinos packages
if [ ! -f cabal.project.local ] && [ -f /home/nyc/src/sarutahiko/cabal.project.local ]; then
  cp -f /home/nyc/src/sarutahiko/cabal.project.local ./cabal.project.local
fi

mkdir -p packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari

# 1. Mount pre-staged seed
cp -f /home/nyc/src/plans/seeds/TP-008C-EditConeLSP.hs packages/hashigakari/hashigakari-core/src/Sarutahiko/Hashigakari/EditConeLSP.hs

# 2. Expose module in hashigakari-core.cabal
python3 -c '
with open("packages/hashigakari/hashigakari-core/hashigakari-core.cabal", "r") as f:
    content = f.read()

if "Sarutahiko.Hashigakari.EditConeLSP" not in content:
    content = content.replace("        Sarutahiko.Hashigakari.Store\n", "        Sarutahiko.Hashigakari.Store\n        Sarutahiko.Hashigakari.EditConeLSP\n")

with open("packages/hashigakari/hashigakari-core/hashigakari-core.cabal", "w") as f:
    f.write(content)
'

# 3. Add test to packages/hashigakari/hashigakari-core/test/Spec.hs
python3 -c '
with open("packages/hashigakari/hashigakari-core/test/Spec.hs", "r") as f:
    content = f.read()

if "Sarutahiko.Hashigakari.EditConeLSP" not in content:
    content = content.replace("import Sarutahiko.Hashigakari.Store\n", "import Sarutahiko.Hashigakari.Store\nimport Sarutahiko.Hashigakari.EditConeLSP\n")

if "prop_edit_cone_early_cutoff" not in content:
    content = content.replace("  [ testProperty \"HashigakariStore Merkle region commit and MVCC lookup\" prop_store_merkle_commit\n", "  [ testProperty \"Hashigakari.EditConeLSP early cutoff\" prop_edit_cone_early_cutoff\n  , testProperty \"HashigakariStore Merkle region commit and MVCC lookup\" prop_store_merkle_commit\n")
    test_code = """
prop_edit_cone_early_cutoff :: Property
prop_edit_cone_early_cutoff = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alpha
  let node1 = HyperNode (DbId 1) name "Haskell" [] 100 "body1"
      node2 = HyperNode (DbId 2) name "Haskell" [] 100 "body2_edited"
      edges = [SheafEdgeLink (DbId 99) (DbId 1) 100]
  checkEarlyCutoffStalk node1 node2 edges === CutoffHaltAtNode (DbId 2)
"""
    content = content.rstrip() + "\n" + test_code

with open("packages/hashigakari/hashigakari-core/test/Spec.hs", "w") as f:
    f.write(content)
'

echo "=== [TP-008C] Building and testing ==="
cabal v2-build hashigakari-core -j20 --semaphore
cabal v2-test hashigakari-core

echo "=== [TP-008C] Script execution complete ==="

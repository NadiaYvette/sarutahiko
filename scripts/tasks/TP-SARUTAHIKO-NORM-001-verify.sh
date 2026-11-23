#!/bin/sh
set -eu

echo "=== Verifying TP-SARUTAHIKO-NORM-001 ==="
echo "1. Checking root stubs are removed..."
test ! -f src/MyLib.hs
test ! -f sarutahiko.cabal

echo "2. Building all packages..."
cabal v2-build --jobs=20 all

echo "3. Running all test suites..."
cabal v2-test --jobs=20 all

echo "4. Running HLint..."
hlint packages/

echo "=== All verifications passed! ==="

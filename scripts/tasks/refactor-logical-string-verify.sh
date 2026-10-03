#!/usr/bin/env bash
set -euo pipefail

echo "=== [refactor-logical-string-verify] Auditing LogicalString and UTF-8 codecs ==="

# 1. Audit cabal build-depends for kogaki-core
if ! grep -q "mono-traversable" packages/kogaki/kogaki-core/kogaki-core.cabal; then
  echo "ERROR: mono-traversable missing from kogaki-core.cabal!"
  exit 1
fi
echo "  [AUDIT PASS] mono-traversable present in kogaki-core.cabal."

# 2. Audit zero calls to partial sequence operations in src dirs
echo "=== [refactor-logical-string-verify] Auditing zero partial functions ==="
if grep -rn "BSC\.head\|BS\.tail\|!!" \
     packages/kogaki/kogaki-core/src \
     packages/kogaki/kogaki-wire/src; then
  echo "ERROR: Partial sequence functions detected in src directories!"
  exit 1
fi
echo "  [AUDIT PASS] Zero partial sequence functions in kogaki-core/src and kogaki-wire/src."

# 3. Run test suites
echo "=== [refactor-logical-string-verify] Running test-kogaki-core ==="
cabal v2-test test-kogaki-core

echo "=== [refactor-logical-string-verify] Running test-kogaki-wire ==="
cabal v2-test test-kogaki-wire

echo "=== [refactor-logical-string-verify] ALL LOGICALSTRING AND UTF-8 CODEC INVARIANT CHECKS PASSED ==="

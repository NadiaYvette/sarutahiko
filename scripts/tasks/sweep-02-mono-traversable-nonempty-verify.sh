#!/usr/bin/env bash
set -euo pipefail

echo "=== [sweep-02-verify] Auditing mono-traversable and non-empty invariants ==="

# 1. Audit cabal build-depends for mono-traversable
for pkg in packages/kogaki/kogaki-wire/kogaki-wire.cabal \
           packages/sarutahiko/sarutahiko-jsonrpc/sarutahiko-jsonrpc.cabal \
           packages/sarutahiko/sarutahiko-mcp/sarutahiko-mcp.cabal; do
  if ! grep -q "mono-traversable" "$pkg"; then
    echo "ERROR: mono-traversable missing from $pkg!"
    exit 1
  fi
done
echo "  [AUDIT PASS] mono-traversable present in all 3 target cabal files."

# 2. Audit zero calls to partial sequence operations in src dirs
echo "=== [sweep-02-verify] Auditing zero partial functions ==="
if grep -rn "BSC\.head\|BS\.tail" \
     packages/kogaki/kogaki-wire/src \
     packages/sarutahiko/sarutahiko-jsonrpc/src \
     packages/sarutahiko/sarutahiko-mcp/src; then
  echo "ERROR: Partial sequence functions detected in src directories!"
  exit 1
fi
echo "  [AUDIT PASS] Zero partial sequence functions in kogaki-wire/src, sarutahiko-jsonrpc/src, and sarutahiko-mcp/src."

# 3. Run test suites
echo "=== [sweep-02-verify] Running test-kogaki-wire ==="
cabal v2-test test-kogaki-wire

echo "=== [sweep-02-verify] Running test-jsonrpc ==="
cabal v2-test test-jsonrpc

echo "=== [sweep-02-verify] Running test-mcp ==="
cabal v2-test test-mcp

echo "=== [sweep-02-verify] ALL NON-EMPTY INVARIANT CHECKS PASSED ==="

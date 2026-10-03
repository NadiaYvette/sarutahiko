#!/usr/bin/env bash
set -euo pipefail

echo "=== [sweep-01-verify] Auditing effect neutrality in sarutahiko-process & sarutahiko-mcp ==="

# 1. Audit: zero references to Effectful in sarutahiko-process/src and sarutahiko-mcp/src
if grep -rn "Effectful" packages/sarutahiko/sarutahiko-process/src packages/sarutahiko/sarutahiko-mcp/src; then
  echo "ERROR: Found direct Effectful imports in neutral packages!"
  exit 1
fi
echo "  [AUDIT PASS] Zero Effectful imports in sarutahiko-process/src and sarutahiko-mcp/src"

# 2. Audit: zero effectful-core dependency in cabal files
if grep -rn "effectful-core" packages/sarutahiko/sarutahiko-process/sarutahiko-process.cabal packages/sarutahiko/sarutahiko-mcp/sarutahiko-mcp.cabal; then
  echo "ERROR: Found effectful-core in cabal build-depends!"
  exit 1
fi
echo "  [AUDIT PASS] Zero effectful-core dependency in sarutahiko-process.cabal and sarutahiko-mcp.cabal"

# 3. Test: run parity tests
echo "=== [sweep-01-verify] Running dual-interpreter parity testkit ==="
cabal v2-test sarutahiko-effect-testkit

# 4. Test: run sarutahiko-process supervisor tests
echo "=== [sweep-01-verify] Running sarutahiko-process tests ==="
cabal v2-test test-process

echo "=== [sweep-01-verify] ALL VERIFICATION CHECKS PASSED ==="

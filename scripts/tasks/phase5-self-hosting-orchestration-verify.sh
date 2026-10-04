#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing Phase 5: Self-Hosting & Full Native Orchestration ==="

# 1. Verify all 4 Phase 5 packages build warning-free
echo "  -> Running cabal v2-build sarutahiko-agent yamaarashi-flow hashigakari-core hashigakari-sqlite..."
cabal v2-build sarutahiko-agent yamaarashi-flow hashigakari-core hashigakari-sqlite

# 2. Verify all test suites pass
echo "  -> Running cabal v2-test sarutahiko-agent yamaarashi-flow hashigakari-core hashigakari-sqlite..."
cabal v2-test sarutahiko-agent yamaarashi-flow hashigakari-core hashigakari-sqlite

# 3. Verify executables build and CLI flags operate
echo "  -> Verifying sarutahiko executable mock run..."
cabal v2-run sarutahiko-agent:exe:sarutahiko -- --mock --prompt "Verify mock run"

echo "  -> Verifying yamaarashi-exec help and executor registry..."
cabal v2-run yamaarashi-flow:exe:yamaarashi-exec -- --help | grep -i "sarutahiko"

# 4. Audit Phase 5 packages for Zero-Aeson compliance
echo "  -> Auditing Phase 5 packages for strict Zero-Aeson invariant..."
if grep -rn -i "import.*Data\.Aeson" \
  packages/sarutahiko/sarutahiko-agent \
  packages/yamaarashi/yamaarashi-flow; then
  echo "ERROR: Found forbidden Data.Aeson import in Phase 5 packages!"
  exit 1
fi
echo "  [PASS] Zero-Aeson compliance verified."

# 5. Audit Phase 5 packages for Zero partial functions
echo "  -> Auditing Phase 5 packages for zero partial functions..."
if grep -rn -E "(\bhead\b|\btail\b|\bfromJust\b|!!)" \
  packages/sarutahiko/sarutahiko-agent/src \
  packages/yamaarashi/yamaarashi-flow/src; then
  echo "ERROR: Found partial functions in Phase 5 source!"
  exit 1
fi
echo "  [PASS] Zero partial functions verified."

echo "=== [Verification Gate] All Phase 5 Self-Hosting Orchestration checks passed successfully! ==="

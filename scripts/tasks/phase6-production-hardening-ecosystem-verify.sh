#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing Phase 6: Production Hardening & Full Ecosystem Integration ==="

# 1. Verify all 6 Phase 6 packages build warning-free
echo "  -> Running cabal v2-build sarutahiko-agent sarutahiko-tui sarutahiko-gateway yamaarashi-flow hashigakari-syntax hashigakari-hasql..."
cabal v2-build sarutahiko-agent sarutahiko-tui sarutahiko-gateway yamaarashi-flow hashigakari-syntax hashigakari-hasql

# 2. Verify all test suites pass
echo "  -> Running cabal v2-test sarutahiko-agent sarutahiko-tui sarutahiko-gateway yamaarashi-flow hashigakari-syntax hashigakari-hasql..."
cabal v2-test sarutahiko-agent sarutahiko-tui sarutahiko-gateway yamaarashi-flow hashigakari-syntax hashigakari-hasql

# 3. Verify CLI execution
echo "  -> Verifying sarutahiko executable mock run..."
cabal v2-run sarutahiko-agent:exe:sarutahiko -- --mock --prompt "Phase 6 self-check"

echo "  -> Verifying yamaarashi-exec kanban projection..."
cabal v2-run yamaarashi-flow:exe:yamaarashi-exec -- kanban .yamaarashi/events.sqlite3 | grep -i "DONE"

# 4. Audit Phase 6 packages for Zero-Aeson compliance
echo "  -> Auditing Phase 6 packages for strict Zero-Aeson invariant..."
if grep -rn -i "import.*Data\.Aeson" \
  packages/sarutahiko/sarutahiko-agent \
  packages/sarutahiko/sarutahiko-tui \
  packages/sarutahiko/sarutahiko-gateway \
  packages/yamaarashi/yamaarashi-flow \
  packages/hashigakari/hashigakari-syntax \
  packages/hashigakari/hashigakari-hasql; then
  echo "ERROR: Found forbidden Data.Aeson import in Phase 6 packages!"
  exit 1
fi
echo "  [PASS] Zero-Aeson compliance verified."

# 5. Audit Phase 6 packages for Zero partial functions
echo "  -> Auditing Phase 6 packages for zero partial functions..."
if grep -rn -E "(\bhead\b|\btail\b|\bfromJust\b|!!)" \
  packages/sarutahiko/sarutahiko-agent/src \
  packages/sarutahiko/sarutahiko-tui/src \
  packages/sarutahiko/sarutahiko-gateway/src \
  packages/yamaarashi/yamaarashi-flow/src \
  packages/hashigakari/hashigakari-syntax/src \
  packages/hashigakari/hashigakari-hasql/src; then
  echo "ERROR: Found partial functions in Phase 6 source!"
  exit 1
fi
echo "  [PASS] Zero partial functions verified."

echo "=== [Verification Gate] All Phase 6 Production Hardening & Ecosystem Integration checks passed successfully! ==="

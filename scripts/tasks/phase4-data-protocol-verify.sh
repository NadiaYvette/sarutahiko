#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing Phase 4: Data Protocols ==="

# 1. Verify all 4 Phase 4 packages build warning-free
echo "  -> Running cabal v2-build hashigakari-core hashigakari-syntax hashigakari-hasql sarutahiko-format-dhall..."
cabal v2-build hashigakari-core hashigakari-syntax hashigakari-hasql sarutahiko-format-dhall

# 2. Verify all test suites pass
echo "  -> Running cabal v2-test hashigakari-core hashigakari-syntax hashigakari-hasql sarutahiko-format-dhall..."
cabal v2-test hashigakari-core hashigakari-syntax hashigakari-hasql sarutahiko-format-dhall

# 3. Audit Phase 4 packages for Zero-Aeson compliance
echo "  -> Auditing Phase 4 packages for strict Zero-Aeson invariant..."
if grep -rn -i "import.*Data\.Aeson" \
  packages/hashigakari/hashigakari-core \
  packages/hashigakari/hashigakari-syntax \
  packages/hashigakari/hashigakari-hasql \
  packages/sarutahiko/sarutahiko-format-dhall; then
  echo "ERROR: Found forbidden Data.Aeson import in Phase 4 packages!"
  exit 1
fi
echo "  [PASS] Zero-Aeson compliance verified."

# 4. Audit Phase 4 packages for Zero partial functions
echo "  -> Auditing Phase 4 packages for zero partial functions..."
if grep -rn -E "(\bhead\b|\btail\b|\bfromJust\b|!!)" \
  packages/hashigakari/hashigakari-core/src \
  packages/hashigakari/hashigakari-syntax/src \
  packages/hashigakari/hashigakari-hasql/src \
  packages/sarutahiko/sarutahiko-format-dhall/src; then
  echo "ERROR: Found partial functions in Phase 4 source!"
  exit 1
fi
echo "  [PASS] Zero partial functions verified."

echo "=== [Verification Gate] All Phase 4 Data Protocol checks passed successfully! ==="

#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing Phase 3: Surfaces & Code Intelligence ==="

# 1. Verify all 4 Phase 3 packages build warning-free
echo "  -> Running cabal v2-build sarutahiko-tui sarutahiko-gateway sarutahiko-acp sarutahiko-tags..."
cabal v2-build sarutahiko-tui sarutahiko-gateway sarutahiko-acp sarutahiko-tags

# 2. Verify all test suites pass
echo "  -> Running cabal v2-test sarutahiko-tui sarutahiko-gateway sarutahiko-acp sarutahiko-tags..."
cabal v2-test sarutahiko-tui sarutahiko-gateway sarutahiko-acp sarutahiko-tags

# 3. Verify sarutahiko-tags executable runs in Vi/Ex ctags mode
echo "  -> Testing sarutahiko-tags on in-tree Haskell source (Vi ctags format)..."
cabal v2-run sarutahiko-tags:exe:sarutahiko-tags -- packages/sarutahiko/sarutahiko-tags/src/Sarutahiko/Tags.hs

# 4. Verify sarutahiko-tags executable runs in Universal Ctags JSON mode
echo "  -> Testing sarutahiko-tags on in-tree Haskell source (JSON Lines format)..."
cabal v2-run sarutahiko-tags:exe:sarutahiko-tags -- --json packages/sarutahiko/sarutahiko-tags/src/Sarutahiko/Tags.hs

# 5. Audit Phase 3 packages for Zero-Aeson compliance
echo "  -> Auditing Phase 3 packages for strict Zero-Aeson invariant..."
if grep -rn -i "import.*Data\.Aeson" packages/sarutahiko/sarutahiko-tui packages/sarutahiko/sarutahiko-gateway packages/sarutahiko/sarutahiko-acp packages/sarutahiko/sarutahiko-tags; then
  echo "ERROR: Found forbidden Data.Aeson import in Phase 3 packages!"
  exit 1
fi
echo "  [PASS] Zero-Aeson compliance verified."

# 6. Audit Phase 3 packages for Zero partial functions
echo "  -> Auditing Phase 3 packages for zero partial functions..."
if grep -rn -E "(\bhead\b|\btail\b|\bfromJust\b|!!)" packages/sarutahiko/sarutahiko-tui/src packages/sarutahiko/sarutahiko-gateway/src packages/sarutahiko/sarutahiko-acp/src packages/sarutahiko/sarutahiko-tags/src; then
  echo "ERROR: Found partial functions in Phase 3 source!"
  exit 1
fi
echo "  [PASS] Zero partial functions verified."

echo "=== [Verification Gate] All Phase 3 Surfaces & CodeIntel checks passed successfully! ==="

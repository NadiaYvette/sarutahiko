#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-SARUTAHIKO-ROLLUP-001] Starting task execution ==="

# 1. Add //go:build ignore to nadiverse-profile.go and nadiverse_profile_test.go to prevent multiple main() conflicts
if [ -f scripts/tools/nadiverse-profile.go ] && ! grep -q "//go:build ignore" scripts/tools/nadiverse-profile.go; then
  sed -i '1s/^/\/\/go:build ignore\n\n/' scripts/tools/nadiverse-profile.go
  echo "Added //go:build ignore to scripts/tools/nadiverse-profile.go"
fi

if [ -f scripts/tools/nadiverse_profile_test.go ] && ! grep -q "//go:build ignore" scripts/tools/nadiverse_profile_test.go; then
  sed -i '1s/^/\/\/go:build ignore\n\n/' scripts/tools/nadiverse_profile_test.go
  echo "Added //go:build ignore to scripts/tools/nadiverse_profile_test.go"
fi

# 2. Ensure scripts/tools/nadiverse-rollup.go and nadiverse_rollup_test.go are placed
if [ -d "/tmp/sarutahiko-rollup-staging" ]; then
  cp -f /tmp/sarutahiko-rollup-staging/nadiverse-rollup.go scripts/tools/nadiverse-rollup.go
  cp -f /tmp/sarutahiko-rollup-staging/nadiverse_rollup_test.go scripts/tools/nadiverse_rollup_test.go
fi

# 3. Add gated hook in bin/push-all
if [ -f bin/push-all ] && ! grep -q "NADIVERSE_ROLLUP" bin/push-all; then
  cat << 'EOF' >> bin/push-all

if [[ "${NADIVERSE_ROLLUP:-0}" == "1" ]] && command -v nadiverse-rollup >/dev/null 2>&1; then
  echo "==> Triggering Nadiverse live notebook Google Doc rollup..."
  nadiverse-rollup -repo . -tier arch || echo "Warning: nadiverse-rollup failed"
fi
EOF
fi

echo "=== [TP-SARUTAHIKO-ROLLUP-001] Task execution complete ==="

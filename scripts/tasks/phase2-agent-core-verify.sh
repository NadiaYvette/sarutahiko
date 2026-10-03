#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing Phase 2: Agent Core ==="

# 1. Verify all 4 Phase 2 packages build warning-free
echo "  -> Running cabal v2-build sarutahiko-session sarutahiko-hooks sarutahiko-plugins sarutahiko-agent..."
cabal v2-build sarutahiko-session sarutahiko-hooks sarutahiko-plugins sarutahiko-agent

# 2. Verify all test suites pass
echo "  -> Running cabal v2-test sarutahiko-session sarutahiko-hooks sarutahiko-plugins sarutahiko-agent..."
cabal v2-test sarutahiko-session sarutahiko-hooks sarutahiko-plugins sarutahiko-agent

# 3. Verify sarutahiko executable runs end-to-end (both direct answer and tool execution)
echo "  -> Running cabal v2-run sarutahiko-agent:exe:sarutahiko direct answer..."
cabal v2-run sarutahiko-agent:exe:sarutahiko -- run "Hello Sarutahiko verification gate"

echo "  -> Running cabal v2-run sarutahiko-agent:exe:sarutahiko tool invocation..."
cabal v2-run sarutahiko-agent:exe:sarutahiko -- run "call echo"

echo "=== [Verification Gate] All Phase 2 Agent Core checks passed successfully! ==="

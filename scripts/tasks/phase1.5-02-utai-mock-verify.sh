#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing utai ==="

# 1. Verify utai builds warning-free
echo "  -> Running cabal v2-build utai..."
cabal v2-build utai

# 2. Verify test suite passes
echo "  -> Running cabal v2-test utai..."
cabal v2-test utai

echo "=== [Verification Gate] All checks passed successfully! ==="

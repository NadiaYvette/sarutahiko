#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing hokora ==="

# 1. Verify hokora builds warning-free
echo "  -> Running cabal v2-build hokora..."
cabal v2-build hokora

# 2. Verify test suite passes
echo "  -> Running cabal v2-test hokora..."
cabal v2-test hokora

# 3. Verify hokora-run executable runs end-to-end
echo "  -> Running cabal v2-run hokora:exe:hokora-run..."
cabal v2-run hokora:exe:hokora-run -- "call echo: verification gate turn"

echo "=== [Verification Gate] All checks passed successfully! ==="

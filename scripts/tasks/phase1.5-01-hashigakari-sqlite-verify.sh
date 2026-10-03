#!/usr/bin/env bash
set -euo pipefail

echo "=== [Verification Gate] Auditing hashigakari-sqlite ==="

# 1. Verify hashigakari-sqlite builds warning-free
echo "  -> Running cabal v2-build hashigakari-sqlite..."
cabal v2-build hashigakari-sqlite

# 2. Verify test suite passes
echo "  -> Running cabal v2-test hashigakari-sqlite..."
cabal v2-test hashigakari-sqlite

echo "=== [Verification Gate] All checks passed successfully! ==="

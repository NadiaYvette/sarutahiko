#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-SMIRK-007C Verification Gate] ==="

echo "  [1/1] Running yamaarashi test suite..."
cabal test yamaarashi

echo "=== [TP-SMIRK-007C Verification Gate PASSED] ==="

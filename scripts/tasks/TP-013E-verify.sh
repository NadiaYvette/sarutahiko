#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-013E-verify] Running verification gate ==="
cabal v2-build yamaarashi yamaarashi-flow -j20 --semaphore
cabal v2-test yamaarashi
echo "=== [TP-013E-verify] Gate PASS ==="

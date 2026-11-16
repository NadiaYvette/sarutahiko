#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-015C-verify] Running verification gate ==="
cabal v2-build yamaarashi -j20 --semaphore
cabal v2-test yamaarashi
echo "=== [TP-015C-verify] Gate PASS ==="

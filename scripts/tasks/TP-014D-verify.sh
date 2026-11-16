#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-014D-verify] Running verification gate ==="
cabal v2-build yamaarashi -j20 --semaphore
cabal v2-test yamaarashi
echo "=== [TP-014D-verify] Gate PASS ==="

#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-KOG-001B-verify] Running verification gate ==="
cabal v2-build kogaki-core -j20 --semaphore
cabal v2-test kogaki-core
echo "=== [TP-KOG-001B-verify] Gate PASS ==="

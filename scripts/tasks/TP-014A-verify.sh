#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-014A-verify] Running verification gate ==="

echo "--> Building yamaarashi and yamaarashi-flow"
cabal v2-build yamaarashi yamaarashi-flow -j20 --semaphore

echo "--> Running yamaarashi test suite"
cabal v2-test yamaarashi

echo "=== [TP-014A-verify] Gate PASS ==="

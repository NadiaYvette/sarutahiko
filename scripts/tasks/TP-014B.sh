#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-014B] Implementing Yamaarashi.Schedule.TropicalPERT ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Schedule

echo "=== [TP-014B] Verifying build ==="
cabal v2-build yamaarashi -j20 --semaphore

echo "=== [TP-014B] Execution script complete ==="

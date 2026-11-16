#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-014C] Implementing Yamaarashi.Schedule.Quarantine ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/Schedule

echo "=== [TP-014C] Verifying build ==="
cabal v2-build yamaarashi -j20 --semaphore

echo "=== [TP-014C] Execution script complete ==="

#!/usr/bin/env bash
set -euo pipefail

if [ ! -f cabal.project.local ] && [ -f /home/nyc/src/sarutahiko/cabal.project.local ]; then
  cp -f /home/nyc/src/sarutahiko/cabal.project.local ./cabal.project.local
fi

echo "=== [TP-008A-verify] Running verification gate ==="
cabal v2-build hashigakari-core -j20 --semaphore
cabal v2-test hashigakari-core
echo "=== [TP-008A-verify] Gate PASS ==="

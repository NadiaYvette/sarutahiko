#!/bin/sh
set -e
echo "=== [TP-YAMAARASHI-INGEST-001] Running verification gates ==="

cabal --with-compiler=ghc-9.14.1 v2-build lib:yamaarashi
cabal --with-compiler=ghc-9.14.1 v2-test yamaarashi --test-options='-p "Yamaarashi.WorkDAG.Ingest"'
if [ -x ./bin/sarutahiko-verify ]; then ./bin/sarutahiko-verify; fi

echo "=== [TP-YAMAARASHI-INGEST-001] Verification passed ==="

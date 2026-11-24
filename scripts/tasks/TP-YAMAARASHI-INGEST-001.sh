#!/bin/sh
set -e
echo "=== [TP-YAMAARASHI-INGEST-001] Deploying Yamaarashi.WorkDAG.Ingest ==="

mkdir -p packages/yamaarashi/yamaarashi/src/Yamaarashi/WorkDAG packages/yamaarashi/yamaarashi/test
cp -f /tmp/sarutahiko-ingest-staging/packages/yamaarashi/yamaarashi/src/Yamaarashi/WorkDAG/Ingest.hs packages/yamaarashi/yamaarashi/src/Yamaarashi/WorkDAG/
cp -f /tmp/sarutahiko-ingest-staging/packages/yamaarashi/yamaarashi/yamaarashi.cabal packages/yamaarashi/yamaarashi/
cp -f /tmp/sarutahiko-ingest-staging/packages/yamaarashi/yamaarashi/test/Spec.hs packages/yamaarashi/yamaarashi/test/

echo "=== [TP-YAMAARASHI-INGEST-001] Deployment complete ==="

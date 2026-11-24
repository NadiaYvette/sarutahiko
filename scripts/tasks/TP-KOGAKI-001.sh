#!/bin/sh
set -e
echo "=== [TP-KOGAKI-001] Deploying Kogaki.Ontology and Kogaki.Input ==="

mkdir -p packages/kogaki/kogaki-core/src/Kogaki packages/kogaki/kogaki-core/test

cp -f /tmp/sarutahiko-kogaki-staging/src/Kogaki/Ontology.hs packages/kogaki/kogaki-core/src/Kogaki/Ontology.hs
cp -f /tmp/sarutahiko-kogaki-staging/src/Kogaki/Input.hs packages/kogaki/kogaki-core/src/Kogaki/Input.hs
cp -f /tmp/sarutahiko-kogaki-staging/kogaki-core.cabal packages/kogaki/kogaki-core/kogaki-core.cabal
cp -f /tmp/sarutahiko-kogaki-staging/test/Spec.hs packages/kogaki/kogaki-core/test/Spec.hs

echo "=== [TP-KOGAKI-001] Deployment complete ==="

#!/bin/sh
set -e
echo "=== [TP-FLUENT-POLY-001] Deploying fluent-polytropos packages ==="

mkdir -p packages/kogaki/fluent-polytropos-core
mkdir -p packages/kogaki/fluent-polytropos
mkdir -p packages/kogaki/fluent-penelope

cp -rf /tmp/sarutahiko-staging/packages/kogaki/fluent-polytropos-core/* packages/kogaki/fluent-polytropos-core/
cp -rf /tmp/sarutahiko-staging/packages/kogaki/fluent-polytropos/* packages/kogaki/fluent-polytropos/
cp -rf /tmp/sarutahiko-staging/packages/kogaki/fluent-penelope/* packages/kogaki/fluent-penelope/

# Ensure packages are declared in cabal.project
if ! grep -q "fluent-polytropos-core" cabal.project; then
  sed -i '/packages\/kogaki\/kogaki-wire/a \    packages/kogaki/fluent-polytropos-core\n    packages/kogaki/fluent-polytropos\n    packages/kogaki/fluent-penelope' cabal.project
fi

echo "=== [TP-FLUENT-POLY-001] Deployment complete ==="

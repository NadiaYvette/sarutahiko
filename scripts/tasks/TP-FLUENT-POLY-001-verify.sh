#!/bin/sh
set -e
echo "=== [TP-FLUENT-POLY-001] Running verification gates ==="

cabal --with-compiler=ghc-9.14.1 v2-build --ghc-options=-Werror fluent-polytropos-core fluent-polytropos fluent-penelope
cabal --with-compiler=ghc-9.14.1 v2-test fluent-polytropos-core fluent-polytropos fluent-penelope
cabal --with-compiler=ghc-9.12.4 v2-test fluent-polytropos-core fluent-polytropos fluent-penelope
hlint packages/kogaki/
(cd packages/kogaki/fluent-polytropos-core && cabal check)
(cd packages/kogaki/fluent-polytropos && cabal check)
(cd packages/kogaki/fluent-penelope && cabal check)

echo "=== [TP-FLUENT-POLY-001] All verification gates passed! ==="

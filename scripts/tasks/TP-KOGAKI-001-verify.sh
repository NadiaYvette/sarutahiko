#!/bin/sh
set -e
echo "=== [TP-KOGAKI-001] Running verification gates ==="

cabal --with-compiler=ghc-9.14.1 v2-build --ghc-options=-Werror kogaki-core
cabal --with-compiler=ghc-9.14.1 v2-test kogaki-core
cabal --with-compiler=ghc-9.12.4 v2-test kogaki-core
hlint packages/kogaki/

echo "=== [TP-KOGAKI-001] All gates passed successfully ==="

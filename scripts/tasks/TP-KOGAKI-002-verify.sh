#!/bin/sh
set -e
echo "=== [TP-KOGAKI-002] Running verification gates ==="

cabal --with-compiler=ghc-9.14.1 v2-build --ghc-options=-Werror kogaki-locales kogaki-qa
cabal --with-compiler=ghc-9.14.1 v2-test kogaki-locales kogaki-qa
cabal --with-compiler=ghc-9.12.4 v2-test kogaki-locales kogaki-qa
hlint packages/kogaki/
(cd packages/kogaki/kogaki-locales && cabal check)
(cd packages/kogaki/kogaki-qa && cabal check)

echo "=== [TP-KOGAKI-002] All verification gates passed! ==="

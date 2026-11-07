#!/usr/bin/env sh
set -e
cabal v2-build sarutahiko-agent
cabal v2-test sarutahiko-agent

#!/usr/bin/env sh
set -e
cabal v2-build yamaarashi
cabal v2-test yamaarashi

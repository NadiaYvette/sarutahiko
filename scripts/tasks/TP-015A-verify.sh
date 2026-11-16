#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-015A Verification] Building yamaarashi package ==="
cabal v2-build yamaarashi

echo "=== [TP-015A Verification] Running yamaarashi test suite ==="
cabal v2-test yamaarashi

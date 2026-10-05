#!/usr/bin/env bash
set -euo pipefail

# Verification script for Phase 7 Observability & Metrics Integration
# Steps:
# 1. Build all observability related packages.
# 2. (Placeholder) Run the observability orchestration (currently a stub).
# 3. Ensure the build succeeded – this is the verification gate.

echo "[Phase7] Building observability packages..."
# Build the four packages by name
cabal v2-build sarutahiko-observability \
               sarutahiko-metrics \
               sarutahiko-logging \
               sarutahiko-tracing

echo "[Phase7] Build succeeded. Running stub initialization..."
# Run the stub init function via a temp file through cabal exec.
# (runghc does not accept '-' for stdin when invoked via cabal exec.)
TMPSCRIPT=$(mktemp --suffix=.hs)
trap 'rm -f "$TMPSCRIPT"' EXIT
cat > "$TMPSCRIPT" <<'EOF'
import Sarutahiko.Observability (initObservability)
main :: IO ()
main = initObservability
EOF
cabal exec -- runghc "$TMPSCRIPT"

# If we had a real metrics endpoint, we would curl it here, e.g.:
# curl -s http://127.0.0.1:9090/metrics | grep '^model_api_requests_total'

echo "[Phase7] Verification completed successfully."

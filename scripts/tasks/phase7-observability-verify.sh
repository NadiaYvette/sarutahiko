#!/usr/bin/env bash
set -euo pipefail

# Verification script for Phase 7 Observability & Metrics Integration
# Steps:
# 1. Build all observability related packages.
# 2. (Placeholder) Run the observability orchestration (currently a stub).
# 3. Ensure the build succeeded – this is the verification gate.

echo "[Phase7] Building observability packages..."
# Build the four packages and their dependencies
cabal v2-build packages/sarutahiko-observability \
               packages/sarutahiko-metrics \
               packages/sarutahiko-logging \
               packages/sarutahiko-tracing

echo "[Phase7] Build succeeded. Running stub initialization..."
# Run the stub init function via runghc (or via cabal exec if an executable existed).
# Here we simply invoke the stub library's initObservability function using runghc.
# This is a no-op placeholder for future real exporter startup.
runghc - <<'EOF'
import Sarutahiko.Observability (initObservability)
main :: IO ()
main = initObservability
EOF

# If we had a real metrics endpoint, we would curl it here, e.g.:
# curl -s http://127.0.0.1:9090/metrics | grep '^model_api_requests_total'

echo "[Phase7] Verification completed successfully."

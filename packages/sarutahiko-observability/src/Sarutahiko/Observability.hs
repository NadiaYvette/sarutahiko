module Sarutahiko.Observability where

-- | Top‑level orchestration placeholder for observability.
--   In Phase 7 this will spin up the Prometheus exporter,
--   the Jaeger/OTLP trace exporter, and the replay CLI support.
--   For now we expose a dummy initializer that can be linked
--   by other packages.

initObservability :: IO ()
initObservability = putStrLn "[sarutahiko-observability] initialized (stub)"

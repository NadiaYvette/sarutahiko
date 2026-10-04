module Sarutahiko.Tracing where

import qualified Data.Text as T

-- | Effect signature for tracing.
class MonadTracing m where
  startSpan :: T.Text -> m ()
  endSpan   :: T.Text -> m ()

-- | Dummy implementation for IO.
instance MonadTracing IO where
  startSpan name = putStrLn $ "[Tracing] start span: " ++ T.unpack name
  endSpan name   = putStrLn $ "[Tracing] end span: " ++ T.unpack name

-- | Initialize Jaeger/OTLP exporter (stub).
initTracing :: IO ()
initTracing = putStrLn "[Tracing] exporter initialized (stub)"

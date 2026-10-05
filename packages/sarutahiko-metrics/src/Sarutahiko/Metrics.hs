module Sarutahiko.Metrics where

import qualified Data.Text as T

-- | Effect signature for metrics.
class MonadMetrics m where
  incCounter :: T.Text -> m ()
  observeHistogram :: T.Text -> Double -> m ()

-- | Dummy implementation that simply prints.
instance MonadMetrics IO where
  incCounter name = putStrLn $ "[Metrics] inc " ++ T.unpack name
  observeHistogram name val = putStrLn $ "[Metrics] observe " ++ T.unpack name ++ " = " ++ show val

-- | Initialize Prometheus exporter (stub).
initMetrics :: IO ()
initMetrics = putStrLn "[Metrics] Prometheus exporter initialized (stub)"

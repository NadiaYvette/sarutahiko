module Sarutahiko.Logging where

import qualified Data.Text as T

-- | Effect signature for structured logging.
class MonadLogging m where
  logInfo :: T.Text -> m ()
  logError :: T.Text -> m ()

-- | Dummy implementation for IO.
instance MonadLogging IO where
  logInfo msg = putStrLn $ "[Log] INFO: " ++ T.unpack msg
  logError msg = putStrLn $ "[Log] ERROR: " ++ T.unpack msg

-- | Initialize logger (stub).
initLogging :: IO ()
initLogging = putStrLn "[Logging] fast-logger initialized (stub)"

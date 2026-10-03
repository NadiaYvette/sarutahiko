-- |
-- Module      : Sarutahiko.Process
-- Description : Resource-bracketed subprocess supervisor with deadline kills
--
-- Re-exports the process effect signature, smart senders, and production interpreter.
module Sarutahiko.Process
  ( module Sarutahiko.Process.Signature
  , module Sarutahiko.Process.Interpreter
  ) where

import Sarutahiko.Process.Interpreter
import Sarutahiko.Process.Signature

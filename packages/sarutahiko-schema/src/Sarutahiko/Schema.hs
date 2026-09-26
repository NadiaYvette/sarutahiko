-- |
-- Module      : Sarutahiko.Schema
-- Description : Row Descriptors ⇄ JSON Schema Compiler and Offline Validator
--
-- Re-exports the schema types, row compiler, and validator.
module Sarutahiko.Schema
  ( -- * Core Schema AST & Classes
    module Sarutahiko.Schema.Types

    -- * Compilation
  , module Sarutahiko.Schema.Compile

    -- * Offline Validation
  , module Sarutahiko.Schema.Validate
  ) where

import Sarutahiko.Schema.Compile
import Sarutahiko.Schema.Types
import Sarutahiko.Schema.Validate

-- |
-- Module      : Sarutahiko.Schema
-- Description : Row Descriptors ⇄ JSON Schema Compiler and Offline Validator
--
-- Re-exports the schema types, row compiler, and validator.
--
-- === Intellectual Lineage & Attribution
-- This module implements JSON Schema draft-07/2020-12 subset validation,
-- informed by the schema validation requirements of Hermes Agent (Nous Research).
-- See @NOTICE.md@ at the repository root.
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

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Sarutahiko.Tags.Types
-- Description : Core tag definitions, kinds, and index entry records
--
-- Represents symbol definitions, types, functions, modules, and macros
-- conforming to universal-ctags taxonomies.
module Sarutahiko.Tags.Types
  ( -- * Tag Kinds
    TagKind (..)
  , tagKindChar
  , tagKindName
    -- * Tag Entry
  , TagEntry (..)
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Classification of a code symbol.
data TagKind
  = TagFunction
  | TagType
  | TagData
  | TagClass
  | TagModule
  | TagMacro
  | TagVariable
  | TagConstructor
  deriving stock (Eq, Ord, Show, Generic)

-- | Single-letter ctags kind identifier.
tagKindChar :: TagKind -> Char
tagKindChar TagFunction    = 'f'
tagKindChar TagType        = 't'
tagKindChar TagData        = 'd'
tagKindChar TagClass       = 'c'
tagKindChar TagModule      = 'm'
tagKindChar TagMacro       = 'd'
tagKindChar TagVariable    = 'v'
tagKindChar TagConstructor = 'C'

-- | Full descriptive name for universal-ctags JSON Lines.
tagKindName :: TagKind -> Text
tagKindName TagFunction    = "function"
tagKindName TagType        = "type"
tagKindName TagData        = "data"
tagKindName TagClass       = "class"
tagKindName TagModule      = "module"
tagKindName TagMacro       = "macro"
tagKindName TagVariable    = "variable"
tagKindName TagConstructor = "constructor"

-- | Individual symbol tag record.
data TagEntry = TagEntry
  { tagName    :: !Text
  , tagPath    :: !FilePath
  , tagLine    :: !Int
  , tagKind    :: !TagKind
  , tagPattern :: !Text
  , tagScope   :: !(Maybe Text)
  } deriving stock (Eq, Ord, Show, Generic)

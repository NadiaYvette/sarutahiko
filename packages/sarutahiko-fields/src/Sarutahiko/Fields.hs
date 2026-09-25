-- |
-- Module      : Sarutahiko.Fields
-- Description : First-class field datums and registry
module Sarutahiko.Fields
  ( -- * Field Datum
    Field (..)
  ) where

import Data.Text (Text)
import GHC.TypeLits (Symbol)

-- | First-class field datum representing a known schema key.
data Field (k :: Symbol) a = Field
  { fieldName :: !Text
  , fieldDoc  :: !Text
  } deriving stock (Eq, Show)

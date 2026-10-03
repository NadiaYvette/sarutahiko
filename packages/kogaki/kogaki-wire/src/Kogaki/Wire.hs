-- |
-- Module      : Kogaki.Wire
-- Description : Zero-bloat row-native JSON lexing, decoding, and SSE streaming parser
--
-- Re-exports the core wire protocol parsers adhering to the Kogaki Doctrine:
-- zero intermediate AST allocation, direct row slot hydration, and byte-faithful
-- SSE event streaming.
module Kogaki.Wire
  ( -- * JSON Token Lexer
    module Kogaki.Wire.Json.Lexer

    -- * Row-Native JSON Decoding & Encoding
  , module Kogaki.Wire.Json.Decode

    -- * Server-Sent Events (SSE)
  , module Kogaki.Wire.SSE.Parser
  ) where

import Kogaki.Wire.Json.Decode
import Kogaki.Wire.Json.Lexer
import Kogaki.Wire.SSE.Parser

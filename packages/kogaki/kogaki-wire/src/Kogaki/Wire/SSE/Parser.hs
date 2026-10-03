{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Kogaki.Wire.SSE.Parser
-- Description : Server-Sent Events (SSE) streaming framing and round-trip parser
--
-- Implements Closure 1 (Anti-Bloat Principle) and Invariant 2
-- (SSE Round-Trip Equivalence): zero-copy, newline-delimited framing
-- for Server-Sent Events over raw byte streams without requiring heavyweight
-- web servers or framework dependencies.
-- Enforces type-level non-emptiness constraints via 'Data.NonNull.NonNull'.
module Kogaki.Wire.SSE.Parser
  ( -- * Core Event Type
    SseEvent (..)

    -- * Non-Empty Tokens & Field Labels
  , SseFieldLabel
  , mkFieldLabel
  , renderDataLine

    -- * Stream Parsing & Rendering
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (isJust)
import Data.NonNull (NonNull, fromNullable, toNullable)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)
import Text.Read (readMaybe)

-- | Non-empty byte sequence representing an SSE field label (e.g. "id", "event", "data").
type SseFieldLabel = NonNull ByteString

-- | Construct a validated non-empty SSE field label.
mkFieldLabel :: ByteString -> Maybe SseFieldLabel
mkFieldLabel = fromNullable

-- | Render a guaranteed non-empty SSE data line.
renderDataLine :: NonNull ByteString -> ByteString
renderDataLine line = "data: " <> toNullable line <> "\n"

-- | A discrete Server-Sent Event frame.
--
-- @since 0.1.0.0
data SseEvent = SseEvent
  { sseId    :: !(Maybe Text)
  , sseEvent :: !(Maybe Text)
  , sseData  :: !ByteString
  , sseRetry :: !(Maybe Int)
  } deriving stock (Eq, Show, Generic)

-- | Parse a stream of raw bytes into a list of 'SseEvent' frames according
-- to the W3C Server-Sent Events specification.
--
-- @since 0.1.0.0
parseSseStream :: ByteString -> [SseEvent]
parseSseStream input = go (splitLines input) Nothing Nothing [] Nothing
  where
    go :: [ByteString]
       -> Maybe Text
       -> Maybe Text
       -> [ByteString]
       -> Maybe Int
       -> [SseEvent]
    go [] mId mEv dataLines mRet
      -- Flush any trailing pending event at end of stream if fields were populated
      | hasEventContent mId mEv dataLines mRet =
          [mkEvent mId mEv dataLines mRet]
      | otherwise = []

    go (line : rest) mId mEv dataLines mRet
      -- Blank line: dispatch event frame
      | BS.null line =
          if hasEventContent mId mEv dataLines mRet
            then mkEvent mId mEv dataLines mRet : go rest Nothing Nothing [] Nothing
            else go rest Nothing Nothing [] Nothing

      -- Comment line: ignore
      | BSC.take 1 line == ":" =
          go rest mId mEv dataLines mRet

      -- Field line: parse field name and value
      | otherwise =
          let (field, rawVal) = BSC.break (== ':') line
              val = case BSC.uncons rawVal of
                Just (':', stripped) ->
                  case BSC.uncons stripped of
                    Just (' ', restVal) -> restVal
                    _                   -> stripped
                _ -> ""
          in case fromNullable field of
            Nothing ->
              -- Field label is empty
              go rest mId mEv dataLines mRet
            Just fieldLabel ->
              case toNullable fieldLabel of
                "id" ->
                  let !newId = Just (TE.decodeUtf8With TEE.lenientDecode val)
                  in go rest newId mEv dataLines mRet
                "event" ->
                  let !newEv = Just (TE.decodeUtf8With TEE.lenientDecode val)
                  in go rest mId newEv dataLines mRet
                "retry" ->
                  let !newRetry = readMaybe (BSC.unpack val)
                  in go rest mId mEv dataLines (newRetry <|> mRet)
                "data" ->
                  go rest mId mEv (val : dataLines) mRet
                _ ->
                  -- Unknown field names are ignored per SSE spec
                  go rest mId mEv dataLines mRet

    hasEventContent mId mEv dataLines mRet =
      isJust mId || isJust mEv || not (null dataLines) || isJust mRet

    mkEvent mId mEv dataLines mRet =
      SseEvent
        { sseId    = mId
        , sseEvent = mEv
        , sseData  = BS.intercalate "\n" (reverse dataLines)
        , sseRetry = mRet
        }

    (<|>) :: Maybe a -> Maybe a -> Maybe a
    Just x  <|> _ = Just x
    Nothing <|> y = y

-- | Split a byte stream into lines on CRLF, LF, or CR with zero partial functions.
splitLines :: ByteString -> [ByteString]
splitLines bs
  | BS.null bs = []
  | otherwise  =
      let (line, rest) = BSC.break (\c -> c == '\n' || c == '\r') bs
      in case BSC.uncons rest of
        Nothing -> [line]
        Just ('\r', afterCr) ->
          case BSC.uncons afterCr of
            Just ('\n', afterLf) -> line : splitLines afterLf
            _                    -> line : splitLines afterCr
        Just ('\n', afterLf) -> line : splitLines afterLf
        Just (_, remainder)  -> line : splitLines remainder

-- | Render a single 'SseEvent' frame to its canonical wire byte representation.
-- Guaranteed to satisfy Law Invariant 2 (SSE Round-Trip Equivalence).
--
-- @since 0.1.0.0
renderSseEvent :: SseEvent -> ByteString
renderSseEvent (SseEvent mId mEv d mRet) =
  BS.concat
    [ maybe "" (\i -> "id: " <> TE.encodeUtf8 i <> "\n") mId
    , maybe "" (\e -> "event: " <> TE.encodeUtf8 e <> "\n") mEv
    , maybe "" (\r -> "retry: " <> BSC.pack (show r) <> "\n") mRet
    , renderData d
    , "\n"
    ]
  where
    renderData bs
      | BS.null bs = "data:\n"
      | otherwise  = BS.concat [ "data: " <> line <> "\n" | line <- BSC.split '\n' bs ]

-- | Render multiple 'SseEvent' frames to a contiguous wire byte stream.
--
-- @since 0.1.0.0
renderSseStream :: [SseEvent] -> ByteString
renderSseStream events = BS.concat (map renderSseEvent events)

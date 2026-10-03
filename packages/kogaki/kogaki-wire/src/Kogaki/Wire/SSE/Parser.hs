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
module Kogaki.Wire.SSE.Parser
  ( -- * Core Event Type
    SseEvent (..)

    -- * Stream Parsing & Rendering
  , parseSseStream
  , renderSseEvent
  , renderSseStream
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import GHC.Generics (Generic)
import Text.Read (readMaybe)

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
      | BSC.head line == ':' =
          go rest mId mEv dataLines mRet

      -- Field line: parse field name and value
      | otherwise =
          let (field, rawVal) = BSC.break (== ':') line
              val = if not (BS.null rawVal) && BSC.head rawVal == ':'
                      then let stripped = BS.tail rawVal
                           in if not (BS.null stripped) && BSC.head stripped == ' '
                                then BS.tail stripped
                                else stripped
                      else ""
          in case field of
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

-- | Split a byte stream into lines on CRLF, LF, or CR.
splitLines :: ByteString -> [ByteString]
splitLines bs
  | BS.null bs = []
  | otherwise  =
      let (line, rest) = BSC.break (\c -> c == '\n' || c == '\r') bs
      in if BS.null rest
           then [line]
           else case BSC.head rest of
             '\r' ->
               let afterCr = BS.tail rest
               in if not (BS.null afterCr) && BSC.head afterCr == '\n'
                    then line : splitLines (BS.tail afterCr)
                    else line : splitLines afterCr
             '\n' -> line : splitLines (BS.tail rest)
             _    -> line : splitLines rest

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

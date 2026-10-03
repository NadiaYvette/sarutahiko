{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Kogaki.Wire.Json.Lexer
-- Description : Zero-bloat, non-allocating JSON token lexer
--
-- Implements the lean, row-native JSON lexer for Phase 1 (TP-1.1).
-- Tokenizes JSON byte streams directly into unboxed and unpacked tokens
-- without intermediate heap-allocated abstract syntax trees ('Value').
-- Commas and colons are consumed as framing delimiters so downstream
-- row decoders receive clean structural tokens and key-value streams.
module Kogaki.Wire.Json.Lexer
  ( -- * Tokens
    JsonToken (..)

    -- * Lexing
  , lexJson
  , lexJsonEither
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (chr, isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.Read as TR
import GHC.Generics (Generic)
import Numeric (readHex)

-- | Flat, unboxed JSON tokens.
--
-- @since 0.1.0.0
data JsonToken
  = TkObjectOpen
  | TkObjectClose
  | TkArrayOpen
  | TkArrayClose
  | TkKey {-# UNPACK #-} !ByteString
  | TkString {-# UNPACK #-} !Text
  | TkInt {-# UNPACK #-} !Int64
  | TkDouble {-# UNPACK #-} !Double
  | TkBool !Bool
  | TkNull
  deriving stock (Eq, Show, Generic)

-- | Lex a JSON byte stream into a list of tokens. Returns an empty
-- list if the input is malformed or empty.
--
-- @since 0.1.0.0
lexJson :: ByteString -> [JsonToken]
lexJson bs = case lexJsonEither bs of
  Left _    -> []
  Right tks -> tks

-- | Internal parsing context.
data Ctx
  = InObject !ObjState
  | InArray !ArrState
  deriving stock (Eq, Show)

data ObjState
  = ObjExpectKeyOrClose
  | ObjExpectKey
  | ObjExpectColon
  | ObjExpectValue
  | ObjExpectCommaOrClose
  deriving stock (Eq, Show)

data ArrState
  = ArrExpectValueOrClose
  | ArrExpectValue
  | ArrExpectCommaOrClose
  deriving stock (Eq, Show)

-- | Lex a JSON byte stream with explicit error reporting.
--
-- @since 0.1.0.0
lexJsonEither :: ByteString -> Either Text [JsonToken]
lexJsonEither input = go (skipWhitespace input) []
  where
    go :: ByteString -> [Ctx] -> Either Text [JsonToken]
    go !bs []
      | BS.null bs = Right []
      | otherwise  = parseTopLevelValue bs

    go !bs (InObject st : stackRest) =
      case st of
        ObjExpectKeyOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed object"
            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest
            Just ('"', _)    -> parseKeyAndContinue (skipWhitespace bs) stackRest
            Just (c, _)      -> Left ("Expected string key or '}', got: " <> T.singleton c)

        ObjExpectKey ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: expected object key"
            Just ('"', _) -> parseKeyAndContinue (skipWhitespace bs) stackRest
            Just (c, _)   -> Left ("Expected string key, got: " <> T.singleton c)

        ObjExpectColon ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: expected ':'"
            Just (':', rest) -> go (skipWhitespace rest) (InObject ObjExpectValue : stackRest)
            Just (c, _)      -> Left ("Expected ':', got: " <> T.singleton c)

        ObjExpectValue ->
          parseValue bs (InObject ObjExpectCommaOrClose : stackRest)

        ObjExpectCommaOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed object"
            Just ('}', rest) -> (TkObjectClose :) <$> go (skipWhitespace rest) stackRest
            Just (',', rest) -> go (skipWhitespace rest) (InObject ObjExpectKey : stackRest)
            Just (c, _)      -> Left ("Expected ',' or '}', got: " <> T.singleton c)

    go !bs (InArray st : stackRest) =
      case st of
        ArrExpectValueOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed array"
            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest
            Just _           -> parseValue (skipWhitespace bs) (InArray ArrExpectCommaOrClose : stackRest)

        ArrExpectValue ->
          parseValue bs (InArray ArrExpectCommaOrClose : stackRest)

        ArrExpectCommaOrClose ->
          case BSC.uncons (skipWhitespace bs) of
            Nothing -> Left "Unexpected EOF: unclosed array"
            Just (']', rest) -> (TkArrayClose :) <$> go (skipWhitespace rest) stackRest
            Just (',', rest) -> go (skipWhitespace rest) (InArray ArrExpectValue : stackRest)
            Just (c, _)      -> Left ("Expected ',' or ']', got: " <> T.singleton c)

    parseTopLevelValue :: ByteString -> Either Text [JsonToken]
    parseTopLevelValue !bs = parseValue bs []

    parseKeyAndContinue :: ByteString -> [Ctx] -> Either Text [JsonToken]
    parseKeyAndContinue !trimmed !stackRest =
      case BSC.uncons trimmed of
        Just ('"', rest) -> do
          (keyBytes, remainder) <- parseRawString rest
          let !nextStack = InObject ObjExpectColon : stackRest
          (TkKey keyBytes :) <$> go (skipWhitespace remainder) nextStack
        _ -> Left "Expected string key starting with quote"

    parseValue :: ByteString -> [Ctx] -> Either Text [JsonToken]
    parseValue !rawBs !stack = do
      let !bs = skipWhitespace rawBs
      case BSC.uncons bs of
        Nothing -> Left "Unexpected EOF: expected JSON value"
        Just ('{', rest) -> (TkObjectOpen :) <$> go (skipWhitespace rest) (InObject ObjExpectKeyOrClose : stack)
        Just ('[', rest) -> (TkArrayOpen :) <$> go (skipWhitespace rest) (InArray ArrExpectValueOrClose : stack)
        Just ('"', rest) -> do
          (strBytes, remainder) <- parseRawString rest
          let !txt = TE.decodeUtf8With TEE.lenientDecode strBytes
          (TkString txt :) <$> go (skipWhitespace remainder) stack
        Just ('t', _)
          | "true" `BS.isPrefixOf` bs ->
              (TkBool True :) <$> go (skipWhitespace (BS.drop 4 bs)) stack
          | otherwise -> Left "Malformed literal: expected 'true'"
        Just ('f', _)
          | "false" `BS.isPrefixOf` bs ->
              (TkBool False :) <$> go (skipWhitespace (BS.drop 5 bs)) stack
          | otherwise -> Left "Malformed literal: expected 'false'"
        Just ('n', _)
          | "null" `BS.isPrefixOf` bs ->
              (TkNull :) <$> go (skipWhitespace (BS.drop 4 bs)) stack
          | otherwise -> Left "Malformed literal: expected 'null'"
        Just (c, _)
          | c == '-' || isDigit c -> do
              (numTok, remainder) <- parseNumber bs
              (numTok :) <$> go (skipWhitespace remainder) stack
          | otherwise -> Left ("Unexpected character starting value: " <> T.singleton c)

-- | Skip ASCII whitespace bytes (0x20, 0x09, 0x0A, 0x0D).
skipWhitespace :: ByteString -> ByteString
skipWhitespace bs = BS.dropWhile isSpaceByte bs
  where
    isSpaceByte w = w == 32 || w == 9 || w == 10 || w == 13

-- | Parse a double-quoted JSON string (without opening quote), returning
-- the unescaped UTF-8 byte payload and the remaining unparsed input.
parseRawString :: ByteString -> Either Text (ByteString, ByteString)
parseRawString input =
  case BSC.elemIndex '"' input of
    Nothing -> Left "Unterminated string literal"
    Just quoteIdx ->
      let prefix = BS.take quoteIdx input
      in if not (BSC.elem '\\' prefix)
           then Right (prefix, BS.drop (quoteIdx + 1) input)
           else slowUnescape input []

slowUnescape :: ByteString -> [ByteString] -> Either Text (ByteString, ByteString)
slowUnescape !bs !acc =
  case BSC.uncons bs of
    Nothing -> Left "Unterminated string literal during escape parsing"
    Just ('"', rest) -> Right (BS.concat (reverse acc), rest)
    Just ('\\', rest) ->
      case BSC.uncons rest of
        Nothing -> Left "Unexpected EOF following escape character '\\'"
        Just ('"', rest2) -> slowUnescape rest2 ("\"" : acc)
        Just ('\\', rest2) -> slowUnescape rest2 ("\\" : acc)
        Just ('/', rest2)  -> slowUnescape rest2 ("/" : acc)
        Just ('b', rest2)  -> slowUnescape rest2 ("\b" : acc)
        Just ('f', rest2)  -> slowUnescape rest2 ("\f" : acc)
        Just ('n', rest2)  -> slowUnescape rest2 ("\n" : acc)
        Just ('r', rest2)  -> slowUnescape rest2 ("\r" : acc)
        Just ('t', rest2)  -> slowUnescape rest2 ("\t" : acc)
        Just ('u', rest2)  -> parseUnicodeEscape rest2 acc
        Just (esc, _)      -> Left ("Invalid escape character in string: \\" <> T.singleton esc)
    Just _ ->
      let (chunk, remainder) = BSC.span (\c -> c /= '"' && c /= '\\') bs
      in slowUnescape remainder (chunk : acc)

parseUnicodeEscape :: ByteString -> [ByteString] -> Either Text (ByteString, ByteString)
parseUnicodeEscape !bs !acc
  | BS.length bs < 4 = Left "Premature EOF in \\u unicode escape"
  | otherwise =
      let hexSlice = BSC.unpack (BS.take 4 bs)
          remBs    = BS.drop 4 bs
      in case readHex hexSlice of
        [(code, "")] ->
          if code >= 0xD800 && code <= 0xDBFF
            then if BS.length remBs >= 6 && BS.take 2 remBs == "\\u"
                   then let lowHex = BSC.unpack (BS.take 4 (BS.drop 2 remBs))
                            afterLow = BS.drop 6 remBs
                        in case readHex lowHex of
                             [(lowCode, "")] | lowCode >= 0xDC00 && lowCode <= 0xDFFF ->
                               let scalar = 0x10000 + ((code - 0xD800) `shiftL` 10) .|. (lowCode - 0xDC00)
                                   encoded = TE.encodeUtf8 (T.singleton (chr scalar))
                               in slowUnescape afterLow (encoded : acc)
                             _ ->
                               let encoded = TE.encodeUtf8 (T.singleton (chr code))
                               in slowUnescape remBs (encoded : acc)
                   else
                     let encoded = TE.encodeUtf8 (T.singleton (chr code))
                     in slowUnescape remBs (encoded : acc)
            else
              let encoded = TE.encodeUtf8 (T.singleton (chr code))
              in slowUnescape remBs (encoded : acc)
        _ -> Left ("Invalid hex in \\u unicode escape: " <> T.pack hexSlice)

-- | Parse a JSON number into either 'TkInt' or 'TkDouble'.
parseNumber :: ByteString -> Either Text (JsonToken, ByteString)
parseNumber !bs =
  let (numBytes, remainder) = BSC.span isNumChar bs
  in if BS.null numBytes
       then Left "Expected number characters"
       else
         if BSC.elem '.' numBytes || BSC.elem 'e' numBytes || BSC.elem 'E' numBytes
           then case TR.double (TE.decodeUtf8With TEE.lenientDecode numBytes) of
             Right (d, rest) | T.null rest -> Right (TkDouble d, remainder)
             _                             -> Left ("Malformed float literal: " <> TE.decodeUtf8With TEE.lenientDecode numBytes)
           else case BSC.readInteger numBytes of
             Just (i, rest) | BS.null rest -> Right (TkInt (fromIntegral i), remainder)
             _                             -> Left ("Malformed integer literal: " <> TE.decodeUtf8With TEE.lenientDecode numBytes)
  where
    isNumChar c = c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' || isDigit c

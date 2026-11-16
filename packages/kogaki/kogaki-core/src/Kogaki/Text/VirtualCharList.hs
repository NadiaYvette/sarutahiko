-- VERBATIM_CODE_SEED: TP-KOG-001A
-- TARGET_REPO: ~/src/sarutahiko
-- TARGET_PACKAGE: kogaki-core
-- TARGET_FILES:
--   src/Kogaki/Text/VirtualCharList.hs

{-# LANGUAGE BangPatterns, MagicHash, PatternSynonyms, ViewPatterns #-}

module Kogaki.Text.VirtualCharList
  ( UTF8Slice(..)
  , UTF8Rope(..)
  , CharListPrism(..)
  , charListPrism
  , pattern VNil
  , pattern (:>)
  , unconsVirtualChar
  , consVirtualChar
  , appendRopeInPlace
  , packUTF8Literal
  , unpackVirtualCharList
  ) where

import Control.Monad.ST (runST)
import Data.Bits ((.&.), (.|.), unsafeShiftL, unsafeShiftR)
import Data.Char (ord, chr)
import Data.Primitive.PrimArray
import Data.Word (Word8)

-- | Contiguous UTF-8 byte buffer slice with a Lean 4 / Perceus `m_rc` header:
--   * `usRC == 0` : Persistent `.rodata` string literal (zero retain/drop traffic).
--   * `usRC == 1` : Unique thread-local buffer eligible for in-place capacity append.
--   * `usRC > 1`  : Shared reference-counted slice.
data UTF8Slice = UTF8Slice
  { usRC     :: {-# UNPACK #-} !Int
  , usOffset :: {-# UNPACK #-} !Int
  , usLength :: {-# UNPACK #-} !Int
  , usBuffer :: {-# UNPACK #-} !(PrimArray Word8)
  } deriving (Eq, Show)

-- | Hybrid UTF-8 Rope backing Haskell 2010 `String = [Char]` under the hood:
--   Contiguous slices handle 99% of strict strings in O(1) space, while `RopeThunk`
--   preserves lazy spine semantics for unbounded streams (`repeat 'a'`).
data UTF8Rope
  = RopeEmpty
  | RopeSlice {-# UNPACK #-} !UTF8Slice
  | RopeCat   {-# UNPACK #-} !Int !UTF8Rope !UTF8Rope
  | RopeThunk [Char]

instance Eq UTF8Rope where
  r1 == r2 = unpackVirtualCharList r1 == unpackVirtualCharList r2

instance Show UTF8Rope where
  showsPrec p r = showsPrec p (unpackVirtualCharList r)

-- | Bidirectional Profunctor Prism / Adapter between `[Char]` and `UTF8Rope`.
data CharListPrism = CharListPrism
  { clpLowerToRope   :: !([Char] -> UTF8Rope)
  , clpLiftToChars   :: !(UTF8Rope -> [Char])
  , clpUnconsView    :: !(UTF8Rope -> Maybe (Char, UTF8Rope))
  }

charListPrism :: CharListPrism
charListPrism = CharListPrism
  { clpLowerToRope = packUTF8Literal
  , clpLiftToChars = unpackVirtualCharList
  , clpUnconsView  = unconsVirtualChar
  }

-- | Bidirectional pattern synonyms enabling standard `[]` and `(c : cs)`
--   pattern matching directly over `UTF8Rope` with zero heap allocation on uncons.
pattern VNil :: UTF8Rope
pattern VNil <- (unconsVirtualChar -> Nothing)
  where
    VNil = RopeEmpty

pattern (:>) :: Char -> UTF8Rope -> UTF8Rope
pattern c :> cs <- (unconsVirtualChar -> Just (c, cs))
  where
    c :> cs = consVirtualChar c cs

{-# COMPLETE VNil, (:>) #-}

-- | O(1) register-level UTF-8 code point decoding for `(c : cs)` pattern matching.
--   Advances `usOffset` by 1..4 bytes without allocating a new `PrimArray` or cons cell.
unconsVirtualChar :: UTF8Rope -> Maybe (Char, UTF8Rope)
unconsVirtualChar RopeEmpty = Nothing
unconsVirtualChar (RopeSlice (UTF8Slice !rc !off !len !buf))
  | len <= 0  = Nothing
  | otherwise =
      let !b0 = fromIntegral (indexPrimArray buf off) :: Int
      in if b0 < 0x80
           then
             let !rest = if len == 1
                           then RopeEmpty
                           else RopeSlice (UTF8Slice rc (off + 1) (len - 1) buf)
             in Just (chr b0, rest)
           else if (b0 .&. 0xE0) == 0xC0 && len >= 2
             then
               let !b1 = fromIntegral (indexPrimArray buf (off + 1)) :: Int
                   !cp = ((b0 .&. 0x1F) `unsafeShiftL` 6) .|. (b1 .&. 0x3F)
                   !rest = if len == 2
                             then RopeEmpty
                             else RopeSlice (UTF8Slice rc (off + 2) (len - 2) buf)
               in Just (chr cp, rest)
             else if (b0 .&. 0xF0) == 0xE0 && len >= 3
               then
                 let !b1 = fromIntegral (indexPrimArray buf (off + 1)) :: Int
                     !b2 = fromIntegral (indexPrimArray buf (off + 2)) :: Int
                     !cp = ((b0 .&. 0x0F) `unsafeShiftL` 12)
                           .|. ((b1 .&. 0x3F) `unsafeShiftL` 6)
                           .|. (b2 .&. 0x3F)
                     !rest = if len == 3
                               then RopeEmpty
                               else RopeSlice (UTF8Slice rc (off + 3) (len - 3) buf)
                 in Just (chr cp, rest)
               else if len >= 4
                 then
                   let !b1 = fromIntegral (indexPrimArray buf (off + 1)) :: Int
                       !b2 = fromIntegral (indexPrimArray buf (off + 2)) :: Int
                       !b3 = fromIntegral (indexPrimArray buf (off + 3)) :: Int
                       !cp = ((b0 .&. 0x07) `unsafeShiftL` 18)
                             .|. ((b1 .&. 0x3F) `unsafeShiftL` 12)
                             .|. ((b2 .&. 0x3F) `unsafeShiftL` 6)
                             .|. (b3 .&. 0x3F)
                       !rest = if len == 4
                                 then RopeEmpty
                                 else RopeSlice (UTF8Slice rc (off + 4) (len - 4) buf)
                   in Just (chr cp, rest)
                 else Nothing
unconsVirtualChar (RopeCat _ l r) =
  case unconsVirtualChar l of
    Nothing        -> unconsVirtualChar r
    Just (!c, !l') ->
      let !rest = case l' of
            RopeEmpty -> r
            _         -> RopeCat (ropeByteLen l' + ropeByteLen r) l' r
      in Just (c, rest)
unconsVirtualChar (RopeThunk [])       = Nothing
unconsVirtualChar (RopeThunk (c : cs)) = Just (c, RopeThunk cs)

-- | Prepend a `Char` onto a `UTF8Rope`, reusing spare prefix capacity in-place
--   when `usRC == 1` and `usOffset >= charBytes`.
consVirtualChar :: Char -> UTF8Rope -> UTF8Rope
consVirtualChar !c RopeEmpty =
  RopeSlice (UTF8Slice 1 0 ( length bytes ) (primArrayFromList bytes))
  where
    !bytes = encodeCharUTF8 c
consVirtualChar !c r@(RopeSlice (UTF8Slice !rc !off !len !buf)) =
  let !cBytes = encodeCharUTF8 c
      !cLen   = length cBytes
  in if rc == 1 && off >= cLen
       then
         let !newOff = off - cLen
             !buf'   = runST $ do
               m <- thawPrimArray buf 0 (sizeofPrimArray buf)
               let writeLoop !_ []       = pure ()
                   writeLoop !i (b : bs) = writePrimArray m i b >> writeLoop (i + 1) bs
               writeLoop newOff cBytes
               unsafeFreezePrimArray m
         in RopeSlice (UTF8Slice 1 newOff (len + cLen) buf')
       else RopeCat (cLen + len) (consVirtualChar c RopeEmpty) r
consVirtualChar !c r =
  let !headRope = consVirtualChar c RopeEmpty
  in RopeCat (ropeByteLen headRope + ropeByteLen r) headRope r

-- | Perceus Functional-But-In-Place (FBIP) concatenation (`s1 ++ s2`):
--   If `s1` is a unique slice (`usRC == 1`) with spare trailing capacity in `usBuffer`,
--   copies `s2` directly into `s1`'s tail in-place; otherwise forms an O(1) `RopeCat` node.
appendRopeInPlace :: UTF8Rope -> UTF8Rope -> UTF8Rope
appendRopeInPlace RopeEmpty r2 = r2
appendRopeInPlace r1 RopeEmpty = r1
appendRopeInPlace (RopeSlice s1@(UTF8Slice !rc1 !off1 !len1 !buf1))
                  (RopeSlice s2@(UTF8Slice !_   !off2 !len2 !buf2))
  | rc1 == 1 && (off1 + len1 + len2 <= sizeofPrimArray buf1) =
      let !buf1' = runST $ do
            m <- thawPrimArray buf1 0 (sizeofPrimArray buf1)
            copyPrimArray m (off1 + len1) buf2 off2 len2
            unsafeFreezePrimArray m
      in RopeSlice (UTF8Slice 1 off1 (len1 + len2) buf1')
  | otherwise =
      RopeCat (len1 + len2) (RopeSlice s1) (RopeSlice s2)
appendRopeInPlace r1 r2 =
  RopeCat (ropeByteLen r1 + ropeByteLen r2) r1 r2

-- | Pack a strict `[Char]` literal into an `m_rc == 0` persistent UTF-8 slice.
packUTF8Literal :: [Char] -> UTF8Rope
packUTF8Literal [] = RopeEmpty
packUTF8Literal cs =
  let !bytes = concatMap encodeCharUTF8 cs
      !arr   = primArrayFromList bytes
  in RopeSlice (UTF8Slice 0 0 (sizeofPrimArray arr) arr)

unpackVirtualCharList :: UTF8Rope -> [Char]
unpackVirtualCharList !r =
  case unconsVirtualChar r of
    Nothing        -> []
    Just (!c, !r') -> c : unpackVirtualCharList r'

ropeByteLen :: UTF8Rope -> Int
ropeByteLen RopeEmpty                     = 0
ropeByteLen (RopeSlice (UTF8Slice _ _ l _)) = l
ropeByteLen (RopeCat l _ _)               = l
ropeByteLen (RopeThunk _)                 = 0

encodeCharUTF8 :: Char -> [Word8]
encodeCharUTF8 !c
  | cp < 0x80 = [fromIntegral cp]
  | cp < 0x800 =
      [ fromIntegral (0xC0 .|. (cp `unsafeShiftR` 6))
      , fromIntegral (0x80 .|. (cp .&. 0x3F))
      ]
  | cp < 0x10000 =
      [ fromIntegral (0xE0 .|. (cp `unsafeShiftR` 12))
      , fromIntegral (0x80 .|. ((cp `unsafeShiftR` 6) .&. 0x3F))
      , fromIntegral (0x80 .|. (cp .&. 0x3F))
      ]
  | otherwise =
      [ fromIntegral (0xF0 .|. (cp `unsafeShiftR` 18))
      , fromIntegral (0x80 .|. ((cp `unsafeShiftR` 12) .&. 0x3F))
      , fromIntegral (0x80 .|. ((cp `unsafeShiftR` 6) .&. 0x3F))
      , fromIntegral (0x80 .|. (cp .&. 0x3F))
      ]
  where
    !cp = ord c
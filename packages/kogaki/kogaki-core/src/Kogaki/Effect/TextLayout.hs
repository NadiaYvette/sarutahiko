-- VERBATIM_CODE_SEED: TP-KOG-001B
-- TARGET_REPO: ~/src/sarutahiko
-- TARGET_PACKAGE: kogaki-core
-- TARGET_FILES:
--   src/Kogaki/Effect/TextLayout.hs

{-# LANGUAGE BangPatterns, DataKinds, GADTs, KindSignatures, PolyKinds #-}

module Kogaki.Effect.TextLayout
  ( BidiDir(..)
  , BidiRun(..)
  , WritingMode(..)
  , VerticalRun(..)
  , GraphemeCluster(..)
  , TextLayoutF(..)
  , segmentGraphemes
  , resolveBidiRuns
  , layoutTateChuYoko
  ) where

import Data.Char (ord, isDigit, isAsciiUpper, isAsciiLower)
import Kogaki.Text.VirtualCharList
  ( UTF8Rope
  , unconsVirtualChar
  , packUTF8Literal
  )

data BidiDir = DirLTR | DirRTL
  deriving (Show, Eq, Ord)

data BidiRun = BidiRun
  { brDir   :: !BidiDir
  , brLevel :: {-# UNPACK #-} !Int
  , brText  :: !UTF8Rope
  } deriving (Show, Eq)

data WritingMode
  = HorizontalTB  -- ^ Standard Latin/Cyrillic/Greek top-to-bottom horizontal flow
  | VerticalRL    -- ^ East Asian traditional right-to-left vertical columns
  | VerticalLR    -- ^ Mongolian / left-to-right vertical columns
  deriving (Show, Eq)

-- | A layout span inside a `VerticalRL` East Asian column:
--   * `VerticalUpright` : Standard upright CJK ideograph / kana cell.
--   * `TateChuYoko`     : Short (1..4 char) horizontal run rotated upright inside a single vertical column width.
--   * `VerticalRotated` : Longer Latin/Arabic run rotated 90 degrees clockwise.
data VerticalRun
  = VerticalUpright !GraphemeCluster
  | TateChuYoko     ![GraphemeCluster]
  | VerticalRotated ![GraphemeCluster]
  deriving (Show, Eq)

newtype GraphemeCluster = GraphemeCluster { unGrapheme :: UTF8Rope }
  deriving (Show, Eq)

-- | First-order Penelope effect signature (`OpF #TextLayout`) for i18n text layout.
data TextLayoutF (ins :: [*]) (exits :: [[*]]) where
  OpSegmentGraphemes
    :: !UTF8Rope
    -> TextLayoutF '[UTF8Rope] '[ '[ [GraphemeCluster] ] ]
  OpResolveBidiRuns
    :: !BidiDir
    -> !UTF8Rope
    -> TextLayoutF '[BidiDir, UTF8Rope] '[ '[ [BidiRun] ] ]
  OpLayoutTateChuYoko
    :: !Int
    -> !UTF8Rope
    -> TextLayoutF '[Int, UTF8Rope] '[ '[ [VerticalRun] ] ]

-- | UAX #29 Extended Grapheme Cluster segmentation over `UTF8Rope`:
--   Keeps base characters fused with combining marks (U+0300..U+036F, variation selectors,
--   Hangul Jamo sequences, and Zero-Width Joiner U+200D emoji sequences).
segmentGraphemes :: UTF8Rope -> [GraphemeCluster]
segmentGraphemes !rope =
  case unconsVirtualChar rope of
    Nothing        -> []
    Just (!c0, !r0) -> go [c0] False r0
  where
    -- `afterZWJ` is True when the previous code point was U+200D (Zero-Width Joiner)
    go !accCluster !afterZWJ !rest =
      case unconsVirtualChar rest of
        Nothing ->
          [GraphemeCluster (packUTF8Literal (reverse accCluster))]
        Just (!c, !rest')
          | c == '\n' && head accCluster == '\r' ->
              GraphemeCluster (packUTF8Literal (reverse (c : accCluster)))
                : segmentGraphemes rest'
          | c == '\x200D' ->
              go (c : accCluster) True rest'
          | afterZWJ || isExtendingMark c ->
              go (c : accCluster) False rest'
          | otherwise ->
              GraphemeCluster (packUTF8Literal (reverse accCluster))
                : go [c] False rest'

isExtendingMark :: Char -> Bool
isExtendingMark !c =
  let !cp = ord c
  in (cp >= 0x0300 && cp <= 0x036F)  -- Combining Diacritical Marks
     || (cp >= 0x1AB0 && cp <= 0x1AFF)
     || (cp >= 0x1DC0 && cp <= 0x1DFF)
     || (cp >= 0x20D0 && cp <= 0x20FF)
     || (cp >= 0xFE00 && cp <= 0xFE0F) -- Variation Selectors
     || (cp >= 0xFE20 && cp <= 0xFE2F)
     || (cp >= 0x1F3FB && cp <= 0x1F3FF) -- Emoji Fitzpatrick Modifiers

-- | UAX #9 Unicode Bidirectional Algorithm run resolver:
--   Segments mixed LTR (Latin/CJK) and RTL (Hebrew/Arabic/Syriac/Thaana) text into
--   directional embedding levels while attaching neutral punctuation to the surrounding run.
resolveBidiRuns :: BidiDir -> UTF8Rope -> [BidiRun]
resolveBidiRuns !baseDir !rope =
  case unconsVirtualChar rope of
    Nothing -> []
    Just (!c0, !r0) ->
      let !initDir = classifyCharDir baseDir c0
      in step initDir [c0] r0
  where
    baseLevel :: BidiDir -> Int
    baseLevel DirLTR = 0
    baseLevel DirRTL = 1

    step !curDir !accChars !rest =
      case unconsVirtualChar rest of
        Nothing ->
          [BidiRun curDir (baseLevel curDir) (packUTF8Literal (reverse accChars))]
        Just (!c, !rest') ->
          let !cDir = classifyCharDir curDir c
          in if cDir == curDir
               then step curDir (c : accChars) rest'
               else
                 BidiRun curDir (baseLevel curDir) (packUTF8Literal (reverse accChars))
                   : step cDir [c] rest'

classifyCharDir :: BidiDir -> Char -> BidiDir
classifyCharDir !ambient !c
  | isStrongRTL (ord c) = DirRTL
  | isNeutral   (ord c) = ambient
  | otherwise           = DirLTR
  where
    isStrongRTL !cp =
      (cp >= 0x0590 && cp <= 0x08FF)     -- Hebrew, Arabic, Syriac, Thaana, NKo
      || (cp >= 0xFB1D && cp <= 0xFDFF)  -- Hebrew & Arabic Presentation Forms-A
      || (cp >= 0xFE70 && cp <= 0xFEFF)  -- Arabic Presentation Forms-B
      || (cp >= 0x10800 && cp <= 0x10FFF)
    isNeutral !cp =
      cp == 0x20 || cp == 0x09 || (cp >= 0x21 && cp <= 0x2F) || (cp >= 0x3A && cp <= 0x40)

-- | East Asian `tate-chu-yoko` (horizontal-in-vertical) layout pass:
--   Groups short runs (of length <= `maxTcyLen`, typically 2..4) of ASCII digits or
--   uppercase acronyms into `TateChuYoko` blocks inside a vertical CJK stream.
layoutTateChuYoko :: Int -> UTF8Rope -> [VerticalRun]
layoutTateChuYoko !maxTcyLen !rope =
  let !clusters = segmentGraphemes rope
  in go clusters
  where
    go [] = []
    go (g : gs)
      | isInlineLatinOrDigit g =
          let (!run, !rest) = span isInlineLatinOrDigit (g : gs)
              !len          = length run
          in if len <= maxTcyLen
               then TateChuYoko run : go rest
               else VerticalRotated run : go rest
      | otherwise =
          VerticalUpright g : go gs

    isInlineLatinOrDigit :: GraphemeCluster -> Bool
    isInlineLatinOrDigit (GraphemeCluster r) =
      case unconsVirtualChar r of
        Just (!c, !tailR) ->
          case unconsVirtualChar tailR of
            Nothing -> isDigit c || isAsciiUpper c || isAsciiLower c
            Just _  -> False
        Nothing -> False
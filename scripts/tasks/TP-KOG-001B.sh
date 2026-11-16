#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-KOG-001B] Deploying Kogaki.Effect.TextLayout ==="

mkdir -p packages/kogaki/kogaki-core/src/Kogaki/Effect

# 1. Mount seed
cp -f /home/nyc/src/plans/seeds/TP-KOG-001B-TextLayout.hs packages/kogaki/kogaki-core/src/Kogaki/Effect/TextLayout.hs

# 2. Expose module in kogaki-core.cabal if not already present
if ! grep -q "Kogaki.Effect.TextLayout" packages/kogaki/kogaki-core/kogaki-core.cabal; then
  sed -i '/Kogaki.Text.VirtualCharList/a \        Kogaki.Effect.TextLayout' packages/kogaki/kogaki-core/kogaki-core.cabal
fi

# 3. Add TextLayout tests to test/Spec.hs
if ! grep -q "Kogaki.Effect.TextLayout" packages/kogaki/kogaki-core/test/Spec.hs; then
  sed -i '/import Kogaki.Text.VirtualCharList/a import Kogaki.Effect.TextLayout' packages/kogaki/kogaki-core/test/Spec.hs
  sed -i '/testGroup "Kogaki.Text.VirtualCharList"/a \  , testGroup "Kogaki.Effect.TextLayout"\n      [ testProperty "segmentGraphemes preserves combining mark grouping" prop_textlayout_graphemes\n      , testProperty "resolveBidiRuns classifies LTR vs RTL" prop_textlayout_bidi\n      , testProperty "layoutTateChuYoko rotates short digit runs upright" prop_textlayout_tcy\n      ]' packages/kogaki/kogaki-core/test/Spec.hs

  cat << 'EOF' >> packages/kogaki/kogaki-core/test/Spec.hs

-- | Grapheme cluster combining mark test.
prop_textlayout_graphemes :: Property
prop_textlayout_graphemes = property $ do
  -- Base 'e' followed by combining acute accent U+0301
  let textWithAccent = packUTF8Literal "e\x0301"
      clusters = segmentGraphemes textWithAccent
  length clusters === 1
  unpackVirtualCharList (unGrapheme (head clusters)) === "e\x0301"

-- | Bidi resolution test.
prop_textlayout_bidi :: Property
prop_textlayout_bidi = property $ do
  let ltrText = packUTF8Literal "Hello World"
      rtlText = packUTF8Literal "\x05D4\x05E2\x05D5\x05DC\x05DD" -- Hebrew Shalom
      runsLTR = resolveBidiRuns DirLTR ltrText
      runsRTL = resolveBidiRuns DirLTR rtlText
  length runsLTR === 1
  brDir (head runsLTR) === DirLTR
  length runsRTL === 1
  brDir (head runsRTL) === DirRTL

-- | Tate-chu-yoko vertical layout test.
prop_textlayout_tcy :: Property
prop_textlayout_tcy = property $ do
  -- Japanese vertical text with short number: "平成30年"
  let mixedText = packUTF8Literal "\x5E73\x6210" <> packUTF8Literal "30" <> packUTF8Literal "\x5E74"
      vruns = layoutTateChuYoko 3 mixedText
  -- Should have: Upright('平'), Upright('成'), TateChuYoko(['3','0']), Upright('年')
  length vruns === 4
  case vruns !! 2 of
    TateChuYoko cs -> length cs === 2
    _              -> failure
EOF
fi

echo "=== [TP-KOG-001B] Building and testing kogaki-core ==="
cabal v2-build kogaki-core -j20 --semaphore
cabal v2-test kogaki-core

echo "=== [TP-KOG-001B] Execution script complete ==="

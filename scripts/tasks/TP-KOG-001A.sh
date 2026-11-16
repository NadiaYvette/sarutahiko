#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-KOG-001A] Deploying Kogaki.Text.VirtualCharList ==="

mkdir -p packages/kogaki/kogaki-core/src/Kogaki/Text

# 1. Mount pre-staged seed
cp -f /home/nyc/src/plans/seeds/TP-KOG-001A-VirtualCharList.hs packages/kogaki/kogaki-core/src/Kogaki/Text/VirtualCharList.hs

# 2. Expose module in kogaki-core.cabal if not already present
if ! grep -q "Kogaki.Text.VirtualCharList" packages/kogaki/kogaki-core/kogaki-core.cabal; then
  sed -i '/exposed-modules:/a \        Kogaki.Text.VirtualCharList,' packages/kogaki/kogaki-core/kogaki-core.cabal
fi

# 3. Add VirtualCharList tests to test/Spec.hs if not already present
if ! grep -q "Kogaki.Text.VirtualCharList" packages/kogaki/kogaki-core/test/Spec.hs; then
  sed -i '/import Kogaki.Core.String/a import Kogaki.Text.VirtualCharList' packages/kogaki/kogaki-core/test/Spec.hs
  sed -i '/testGroup "Kogaki.Core.String"/a \  , testGroup "Kogaki.Text.VirtualCharList"\n      [ testProperty "roundtrip packUTF8Literal and unpackVirtualCharList" prop_virtualchar_roundtrip\n      , testProperty "pattern matching with (:>) and VNil matches [Char]" prop_virtualchar_patterns\n      , testProperty "appendRopeInPlace preserves concatenation" prop_virtualchar_append\n      ]' packages/kogaki/kogaki-core/test/Spec.hs

  cat << 'EOF' >> packages/kogaki/kogaki-core/test/Spec.hs

-- | VirtualCharList round-trip property.
prop_virtualchar_roundtrip :: Property
prop_virtualchar_roundtrip = property $ do
  s <- forAll $ Gen.string (Range.linear 0 300) Gen.unicode
  unpackVirtualCharList (packUTF8Literal s) === s

-- | VirtualCharList pattern synonym equivalence.
prop_virtualchar_patterns :: Property
prop_virtualchar_patterns = property $ do
  s <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  let rope = packUTF8Literal s
  let unpackWithPatterns VNil      = []
      unpackWithPatterns (c :> cs) = c : unpackWithPatterns cs
      unpackWithPatterns _         = error "unreachable"
  unpackWithPatterns rope === s

-- | VirtualCharList append equivalence.
prop_virtualchar_append :: Property
prop_virtualchar_append = property $ do
  s1 <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  s2 <- forAll $ Gen.string (Range.linear 0 100) Gen.unicode
  let r1 = packUTF8Literal s1
      r2 = packUTF8Literal s2
  unpackVirtualCharList (appendRopeInPlace r1 r2) === (s1 ++ s2)
EOF
fi

echo "=== [TP-KOG-001A] Building and testing kogaki-core ==="
cabal v2-build kogaki-core -j20 --semaphore
cabal v2-test kogaki-core

echo "=== [TP-KOG-001A] Execution script complete ==="

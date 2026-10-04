{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Tags

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Tags Test Suite"
  [ testProperty "Haskell source tag extraction identifies modules, types, and functions" prop_extract_haskell
  , testProperty "C source tag extraction identifies macros and functions" prop_extract_c
  , testProperty "Universal Ctags JSON formatting conforms to spec" prop_format_json
  , testProperty "Vi ctags tab-delimited formatting conforms to spec" prop_format_vi
  ]

-- | Sample Haskell code for tag extraction testing.
sampleHaskell :: T.Text
sampleHaskell = T.unlines
  [ "module Foo.Bar where"
  , ""
  , "data MyData = MyDataA | MyDataB"
  , ""
  , "type MyAlias = Int"
  , ""
  , "class MyClass a where"
  , "  classMethod :: a -> Int"
  , ""
  , "myFunction :: Int -> Int"
  , "myFunction x = x + 1"
  ]

-- | Sample C code for tag extraction testing.
sampleC :: T.Text
sampleC = T.unlines
  [ "#define MAX_BUF 1024"
  , ""
  , "struct Point {"
  , "  int x;"
  , "  int y;"
  , "};"
  , ""
  , "int calculate_sum(int a, int b) {"
  , "  return a + b;"
  , "}"
  ]

prop_extract_haskell :: Property
prop_extract_haskell = property $ do
  let tags = extractHaskellTags "Foo/Bar.hs" sampleHaskell
      names = map tagName tags
  assert ("Foo.Bar" `elem` names)
  assert ("MyData" `elem` names)
  assert ("MyAlias" `elem` names)
  assert ("MyClass" `elem` names)
  assert ("myFunction" `elem` names)

prop_extract_c :: Property
prop_extract_c = property $ do
  let tags = extractCTags "point.c" sampleC
      names = map tagName tags
  assert ("MAX_BUF" `elem` names)
  assert ("Point" `elem` names)
  assert ("calculate_sum" `elem` names)

prop_format_json :: Property
prop_format_json = property $ do
  name <- forAll $ Gen.text (Range.linear 3 10) Gen.alphaNum
  path <- forAll $ Gen.string (Range.linear 3 15) Gen.alphaNum
  let tag = TagEntry
        { tagName    = name
        , tagPath    = path
        , tagLine    = 42
        , tagKind    = TagFunction
        , tagPattern = "^" <> name <> "$"
        , tagScope   = Nothing
        }
      json = formatUniversalCtagsJson tag
  assert ("\"_type\":\"tag\"" `BSC.isInfixOf` json)
  assert ("\"kind\":\"function\"" `BSC.isInfixOf` json)
  assert ("\"line\":42" `BSC.isInfixOf` json)

prop_format_vi :: Property
prop_format_vi = property $ do
  name <- forAll $ Gen.text (Range.linear 3 10) Gen.alphaNum
  let tag = TagEntry
        { tagName    = name
        , tagPath    = "src/Lib.hs"
        , tagLine    = 10
        , tagKind    = TagFunction
        , tagPattern = "^" <> name <> "$"
        , tagScope   = Nothing
        }
      line = formatViCtagsLine tag
  assert ("\tsrc/Lib.hs\t/" `BSC.isInfixOf` line)
  assert ("/;\"\t" `BSC.isInfixOf` line)

{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Exit (exitFailure)
import Fluent.Polytropos.Schema
  ( CatalogDiff (..)
  , CatalogSchema (..)
  , MessageSchema (..)
  , ParamType (..)
  , diffCatalogSchemas
  , extractInlineTags
  , parseParamAnnotations
  )

assert :: String -> Bool -> IO ()
assert desc True  = putStrLn ("  [PASS] " ++ desc)
assert desc False = do
  putStrLn ("  [FAIL] " ++ desc)
  exitFailure

main :: IO ()
main = do
  putStrLn "=== fluent-polytropos-core Test Suite ==="

  putStrLn "--- Section 1: Parameter Annotations Parsing ---"
  let comments =
        [ "# @param $count :: Int"
        , "## @param $name :: Text"
        , "# @param $flag :: Verbatim"
        , "# @param $date :: DateTime"
        , "# @param $user :: UserId"
        , "# Non-param comment"
        ]
  let params = parseParamAnnotations comments
  assert "parseParamAnnotations extracts $count :: Int" $
    Map.lookup "count" params == Just ParamNumber
  assert "parseParamAnnotations extracts $name :: Text" $
    Map.lookup "name" params == Just ParamText
  assert "parseParamAnnotations extracts $flag :: Verbatim" $
    Map.lookup "flag" params == Just ParamVerbatim
  assert "parseParamAnnotations extracts $date :: DateTime" $
    Map.lookup "date" params == Just ParamDateTime
  assert "parseParamAnnotations extracts $user :: UserId as custom" $
    Map.lookup "user" params == Just (ParamCustom "UserId")

  putStrLn "--- Section 2: Inline Tag Multiset Extraction ---"
  let patternText = "Hello <flag>--verbose</flag> and <flag>--quiet</flag> with <emph>great</emph> power"
  let tags = extractInlineTags patternText
  assert "extractInlineTags counts 2 <flag> tags" $
    Map.lookup "flag" tags == Just 2
  assert "extractInlineTags counts 1 <emph> tag" $
    Map.lookup "emph" tags == Just 1

  putStrLn "--- Section 3: Structural Catalog Diffing ---"
  let refMsg1 = MessageSchema "msg1" (Map.fromList [("count", ParamNumber)]) (Map.singleton "flag" 1) Set.empty
  let refMsg2 = MessageSchema "msg2" (Map.fromList [("name", ParamText)]) Map.empty Set.empty
  let refCat = CatalogSchema "en" (Map.fromList [("msg1", refMsg1), ("msg2", refMsg2)]) Set.empty

  let tgtMsg1 = MessageSchema "msg1" (Map.fromList [("count", ParamNumber), ("extra", ParamText)]) (Map.singleton "flag" 2) Set.empty
  let tgtMsg3 = MessageSchema "msg3" Map.empty Map.empty Set.empty
  let tgtCat = CatalogSchema "de" (Map.fromList [("msg1", tgtMsg1), ("msg3", tgtMsg3)]) Set.empty

  let diff = diffCatalogSchemas refCat tgtCat
  assert "diff detects missing message msg2" $
    cdMissingMessages diff == Set.singleton "msg2"
  assert "diff detects extra message msg3" $
    cdExtraMessages diff == Set.singleton "msg3"
  assert "diff detects extra parameter in msg1" $
    case Map.lookup "msg1" (cdParamMismatches diff) of
      Just (missing, extra) -> missing == Set.empty && extra == Set.singleton "extra"
      Nothing -> False
  assert "diff detects tag count drift in msg1" $
    case Map.lookup "msg1" (cdTagMismatches diff) of
      Just (refTags, tgtTags) -> Map.lookup "flag" refTags == Just 1 && Map.lookup "flag" tgtTags == Just 2
      Nothing -> False

  putStrLn "=== All fluent-polytropos-core tests passed! ==="

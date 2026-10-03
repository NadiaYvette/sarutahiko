{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.JsonRpc.Types (JsonRpcError (..))
import Sarutahiko.MCP
  ( CallToolResult (..)
  , ClientCapabilities (..)
  , Implementation (..)
  , InitializeParams (..)
  , ListToolsResult (..)
  , ToolContent (..)
  , ToolDef (..)
  , checkStateGuard
  , decodeCallToolResult
  , decodeInitializeParams
  , decodeListToolsResult
  , encodeCallToolResult
  , encodeInitializeParams
  , encodeListToolsResult
  , handleMcpPayload
  , mcpVersion2025_03_26
  , newMcpServer
  , registerTool
  )
import Sarutahiko.Schema.Types (SchemaNode (..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko MCP Test Suite (TP-1.5)"
  [ testGroup "StateGuard Invariant Tests"
      [ testProperty "PropStateGuardRejectionBeforeInit" propStateGuardRejection
      , testProperty "PropHandshakeProgression" propHandshakeProgression
      ]
  , testGroup "Wire Codec Roundtrip Tests"
      [ testProperty "PropInitializeParamsRoundtrip" propInitializeParamsRoundtrip
      , testProperty "PropListToolsResultRoundtrip" propListToolsResultRoundtrip
      , testProperty "PropCallToolResultRoundtrip" propCallToolResultRoundtrip
      ]
  ]

-- | Invariant: checkStateGuard returns Just -32600 for any method other than
-- initialize, ping, or notifications/initialized when uninitialized.
propStateGuardRejection :: Property
propStateGuardRejection = property $ do
  method <- forAll $ Gen.filter (`notElem` ["initialize", "ping", "notifications/initialized"]) $
    Gen.text (Range.linear 1 30) Gen.alphaNum
  case checkStateGuard False method of
    Nothing -> failure
    Just (JsonRpcError code _ _) -> do
      code === -32600

-- | End-to-end handshake progression and StateGuard transition.
propHandshakeProgression :: Property
propHandshakeProgression = property $ do
  server <- liftIO $ newMcpServer (Implementation "test-server" "1.0.0")

  -- Register a test echo tool
  liftIO $ registerTool server
    (ToolDef "echo" (Just "Echo test") (SchemaObject Map.empty []))
    (\mArgs -> pure (CallToolResult [TextContent ("echoed: " <> maybe "" (T.pack . BSC.unpack) mArgs)] False))

  -- Step 1: Pre-initialization tools/list MUST fail with -32600
  resPre <- liftIO $ handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
  case resPre of
    Nothing -> failure
    Just bs -> do
      assert ("\"code\":-32600" `BSC.isInfixOf` bs || "\"-32600\"" `BSC.isInfixOf` bs)

  -- Step 2: initialize handshake
  let initPayload =
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{" <>
        "\"protocolVersion\":\"2025-03-26\"," <>
        "\"capabilities\":{}," <>
        "\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0.0\"}}}"
  resInit <- liftIO $ handleMcpPayload server initPayload
  case resInit of
    Nothing -> failure
    Just bs -> do
      assert ("\"result\"" `BSC.isInfixOf` bs)
      assert ("2025-03-26" `BSC.isInfixOf` bs)

  -- Step 3: Still uninitialized until notifications/initialized arrives!
  resMid <- liftIO $ handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{}}"
  case resMid of
    Nothing -> failure
    Just bs -> do
      assert ("-32600" `BSC.isInfixOf` bs)

  -- Step 4: Send notifications/initialized (notification returns Nothing)
  resNotif <- liftIO $ handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"
  resNotif === Nothing

  -- Step 5: Post-initialization tools/list succeeds!
  resPost <- liftIO $ handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{}}"
  case resPost of
    Nothing -> failure
    Just bs -> do
      assert ("\"result\"" `BSC.isInfixOf` bs)
      assert ("\"echo\"" `BSC.isInfixOf` bs)

  -- Step 6: Invoke tool
  resCall <- liftIO $ handleMcpPayload server "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"msg\":\"hello\"}}}"
  case resCall of
    Nothing -> failure
    Just bs -> do
      assert ("\"result\"" `BSC.isInfixOf` bs)
      assert ("echoed:" `BSC.isInfixOf` bs)

-- | Roundtrip InitializeParams
propInitializeParamsRoundtrip :: Property
propInitializeParamsRoundtrip = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  ver  <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let params = InitializeParams
        { ipProtocolVersion = mcpVersion2025_03_26
        , ipCapabilities     = ClientCapabilities (Just True) (Just False) Nothing
        , ipClientInfo       = Implementation name ver
        }
      bytes = encodeInitializeParams params
  case decodeInitializeParams bytes of
    Left _ -> failure
    Right decoded -> do
      ipProtocolVersion decoded === ipProtocolVersion params
      implName (ipClientInfo decoded) === name
      implVersion (ipClientInfo decoded) === ver

-- | Roundtrip ListToolsResult
propListToolsResultRoundtrip :: Property
propListToolsResultRoundtrip = property $ do
  tName <- forAll $ Gen.text (Range.linear 1 15) Gen.alphaNum
  let tool = ToolDef tName (Just "A tool description") (SchemaObject Map.empty [])
      result = ListToolsResult [tool] (Just "cursor123")
      bytes = encodeListToolsResult result
  case decodeListToolsResult bytes of
    Left _ -> failure
    Right decoded -> do
      case ltrTools decoded of
        [singleTool] -> do
          toolName singleTool === tName
          ltrNextCursor decoded === Just "cursor123"
        _ -> failure

-- | Roundtrip CallToolResult
propCallToolResultRoundtrip :: Property
propCallToolResultRoundtrip = property $ do
  msg <- forAll $ Gen.text (Range.linear 1 40) Gen.unicode
  isErr <- forAll Gen.bool
  let result = CallToolResult [TextContent msg] isErr
      bytes = encodeCallToolResult result
  case decodeCallToolResult bytes of
    Left _ -> failure
    Right decoded -> do
      ctrIsError decoded === isErr
      ctrContent decoded === [TextContent msg]

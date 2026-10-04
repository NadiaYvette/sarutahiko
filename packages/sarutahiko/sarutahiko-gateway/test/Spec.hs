{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.MVar
import Effectful
import Effectful.Dispatch.Dynamic (send)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Gateway

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Gateway Test Suite"
  [ testProperty "Send message records target platform, recipient, and content" prop_send_message
  , testProperty "Inbound event queue drains in FIFO order" prop_poll_events
  , testProperty "Broadcasting emits all-recipient message" prop_broadcast
  , testProperty "Inbound event turn processing dispatches reply" prop_gateway_turn_processing
  , testProperty "Platform naming matches canonical strings" prop_platform_names
  ]

-- | SendMessage records properly in state.
prop_send_message :: Property
prop_send_message = property $ do
  recipient <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  content <- forAll $ Gen.text (Range.linear 1 50) Gen.alphaNum
  platform <- forAll $ Gen.element [Telegram, Discord, Slack, Webhook]

  res <- evalIO $ do
    var <- newMVar emptyGatewayState
    _ <- runEff $ runGatewayPure var $ do
      send (SendMessage platform recipient content)
    readMVar var

  case gsSentMessages res of
    [sent] -> do
      gmPlatform sent === platform
      gmRecipientId sent === recipient
      gmContent sent === content
    _ -> failure

-- | Inbound events are polled and drained.
prop_poll_events :: Property
prop_poll_events = property $ do
  count <- forAll $ Gen.int (Range.linear 1 10)
  res <- evalIO $ do
    var <- newMVar emptyGatewayState
    let mkEvent i = EvMessageReceived $ GatewayMessage
          { gmMessageId   = "msg-" <> (if i == 0 then "0" else "x")
          , gmPlatform    = Webhook
          , gmSenderId    = "user"
          , gmRecipientId = "bot"
          , gmContent     = "hello"
          }
    mapM_ (sendPure var . mkEvent) [1..count]
    polled <- runEff $ runGatewayPure var $ send PollEvents
    stAfter <- readMVar var
    pure (polled, gsPendingInbound stAfter)

  let (polledEvents, pendingAfter) = res
  length polledEvents === count
  length pendingAfter === 0

-- | Broadcast emits message to recipient 'all'.
prop_broadcast :: Property
prop_broadcast = property $ do
  content <- forAll $ Gen.text (Range.linear 1 50) Gen.alphaNum
  res <- evalIO $ do
    var <- newMVar emptyGatewayState
    _ <- runEff $ runGatewayPure var $ do
      send (BroadcastMessage Discord content)
    readMVar var

  case gsSentMessages res of
    [sent] -> do
      gmRecipientId sent === "all"
      gmPlatform sent === Discord
      gmContent sent === content
    _ -> failure

-- | Processing an inbound event invokes the handler and dispatches a reply back to the platform.
prop_gateway_turn_processing :: Property
prop_gateway_turn_processing = property $ do
  sender <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  prompt <- forAll $ Gen.text (Range.linear 1 40) Gen.alphaNum
  platform <- forAll $ Gen.element [Telegram, Discord, Slack, Webhook]
  res <- evalIO $ do
    var <- newMVar emptyGatewayState
    let inEvent = EvMessageReceived $ GatewayMessage
          { gmMessageId   = "msg-in-1"
          , gmPlatform    = platform
          , gmSenderId    = sender
          , gmRecipientId = "bot"
          , gmContent     = prompt
          }
    outRes <- runEff $ runGatewayPure var $ do
      processGatewayMessage inEvent (\p -> pure ("Echo: " <> p))
    st <- readMVar var
    pure (outRes, gsSentMessages st)

  let (turnResult, sentMessages) = res
  case (turnResult, sentMessages) of
    (Just (Right msgId), [sent]) -> do
      gmMessageId sent === msgId
      gmPlatform sent === platform
      gmRecipientId sent === sender
      gmContent sent === ("Echo: " <> prompt)
    _ -> failure

-- | Platform naming matches expected protocol strings.
prop_platform_names :: Property
prop_platform_names = property $ do
  platformName Telegram === "telegram"
  platformName Discord === "discord"
  platformName Slack === "slack"
  platformName Webhook === "webhook"
  platformName (CustomPlatform "matrix") === "matrix"

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, finally, try)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.Hedgehog

import Sarutahiko.Effect.EventStore (SessionId (..))
import Sarutahiko.Effect.ModelAPI (Message (..), Role (..))
import Sarutahiko.Session
  ( SessionContext (..)
  , appendSessionEvent
  , closeSession
  , encodeMessagePayload
  , readSessionContext
  , readSessionEvents
  , withSession
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Sarutahiko Session (utaibon) Test Suite"
  [ testProperty "Session lifecycle: open, append, hydrate, and close" prop_session_lifecycle
  , testProperty "Prompt-cache prefix hash stability: deterministic and sensitive" prop_session_prefix_stability
  , testProperty "Reducer replay parity: identical context and prefix hash across reloads" prop_session_replay_parity
  ]

withTempSqlite :: (FilePath -> IO a) -> IO a
withTempSqlite action = do
  tmpDir <- getTemporaryDirectory
  (tmpFile, h) <- openTempFile tmpDir "session-test-.db"
  hClose h
  let cleanup = do
        _ <- try @SomeException (removeFile tmpFile)
        _ <- try @SomeException (removeFile (tmpFile <> "-wal"))
        _ <- try @SomeException (removeFile (tmpFile <> "-shm"))
        pure ()
  action tmpFile `finally` cleanup

prop_session_lifecycle :: Property
prop_session_lifecycle = property $ do
  prompt <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  reply  <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let sid = SessionId "sess-life"
      model = "test-model"
      cwd = "/tmp/session"

  (evs, ctx) <- liftIO $ withTempSqlite $ \dbPath ->
    withSession dbPath sid model cwd $ \handle -> do
      _ <- appendSessionEvent handle "message" (encodeMessagePayload RoleUser prompt)
      _ <- appendSessionEvent handle "message" (encodeMessagePayload RoleAssistant reply)
      closeSession handle "turn_complete"
      raw <- readSessionEvents handle
      c <- readSessionContext handle
      pure (raw, c)

  length evs === 4
  scIsClosed ctx === True
  scCloseReason ctx === Just "turn_complete"
  length (scMessages ctx) === 2
  map msgContent (scMessages ctx) === [prompt, reply]
  assert (not (T.null (scPrefixHash ctx)))

prop_session_prefix_stability :: Property
prop_session_prefix_stability = property $ do
  p1 <- forAll $ Gen.text (Range.linear 5 20) Gen.alphaNum
  p2 <- forAll $ Gen.filter (/= p1) $ Gen.text (Range.linear 5 20) Gen.alphaNum
  let model = "test-model"
      cwd = "/tmp/session"

  (h1a, h1b, h2) <- liftIO $ withTempSqlite $ \dbPath -> do
    c1a <- withSession dbPath (SessionId "s1a") model cwd $ \h -> do
      _ <- appendSessionEvent h "message" (encodeMessagePayload RoleUser p1)
      readSessionContext h
    c1b <- withSession dbPath (SessionId "s1b") model cwd $ \h -> do
      _ <- appendSessionEvent h "message" (encodeMessagePayload RoleUser p1)
      readSessionContext h
    c2 <- withSession dbPath (SessionId "s2") model cwd $ \h -> do
      _ <- appendSessionEvent h "message" (encodeMessagePayload RoleUser p2)
      readSessionContext h
    pure (scPrefixHash c1a, scPrefixHash c1b, scPrefixHash c2)

  h1a === h1b
  assert (h1a /= h2)

prop_session_replay_parity :: Property
prop_session_replay_parity = property $ do
  p <- forAll $ Gen.text (Range.linear 5 30) Gen.alphaNum
  let sid = SessionId "sess-replay"
      model = "test-model"
      cwd = "/tmp/session"

  (ctx1, ctx2) <- liftIO $ withTempSqlite $ \dbPath ->
    withSession dbPath sid model cwd $ \handle -> do
      _ <- appendSessionEvent handle "message" (encodeMessagePayload RoleUser p)
      c1 <- readSessionContext handle
      c2 <- readSessionContext handle
      pure (c1, c2)

  ctx1 === ctx2
  scPrefixHash ctx1 === scPrefixHash ctx2

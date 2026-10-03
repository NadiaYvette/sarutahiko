{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Concurrent (forkIO, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM, forM_, replicateM)
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int64)
import qualified Data.List as List
import qualified Data.Text as T
import Effectful (runEff)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Hashigakari.Sqlite
import Sarutahiko.Effect.EventStore (SessionId (..), StoredEvent (..))
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskResult (..), WorkerId (..))
import Sarutahiko.Effect.Testkit.STM
import qualified Yamaarashi as Y

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Hashigakari SQLite Carrier & Parity"
  [ testProperty "Dual-interpreter parity: EventStore (SQLite vs STM)" prop_event_store_parity
  , testProperty "Dual-interpreter parity: TaskQueue (SQLite vs STM)" prop_task_queue_parity
  , testProperty "Concurrency: atomic leases prevent duplicate claims across workers" prop_concurrent_leases
  , testProperty "Event tail folds and Yamaarashi stream replay" prop_stream_tail_replay
  ]

-- | Bracketed helper allocating an isolated temporary SQLite database file.
withTempSqlite :: (FilePath -> IO a) -> IO a
withTempSqlite action = do
  tmpDir <- getTemporaryDirectory
  (tmpFile, h) <- openTempFile tmpDir "hashigakari-parity-.db"
  hClose h
  let cleanup = do
        _ <- try @SomeException (removeFile tmpFile)
        _ <- try @SomeException (removeFile (tmpFile <> "-wal"))
        _ <- try @SomeException (removeFile (tmpFile <> "-shm"))
        pure ()
  action tmpFile `finally` cleanup

-- ----------------------------------------------------------------------------
-- Property 1: EventStore Parity (SQLite vs STM)
-- ----------------------------------------------------------------------------

prop_event_store_parity :: Property
prop_event_store_parity = property $ do
  eventCount <- forAll $ Gen.int (Range.linear 1 20)
  events <- forAll $ Gen.list (Range.singleton eventCount) $ do
    evType <- Gen.text (Range.linear 1 10) Gen.alphaNum
    payload <- Gen.bytes (Range.linear 1 50)
    pure (evType, payload)
  let sid = SessionId "session-parity"

  (sqliteEvents, stmEvents) <- evalIO $ withTempSqlite $ \tmpPath -> do
    -- Run on SQLite via capability façade
    sqliteEvs <- withSqliteDatabase tmpPath $ \db -> do
      runEff . runEventStoreSqlite db $ do
        forM_ events $ \(evType, payload) ->
          appendEvent sid evType payload
        readEvents sid

    -- Run on pure in-memory STM via capability façade
    stmVar <- newStmEventStore
    stmEvs <- runEff . runEventStoreSTM stmVar $ do
      forM_ events $ \(evType, payload) ->
        appendEvent sid evType payload
      readEvents sid

    pure (sqliteEvs, stmEvs)

  -- Compare lengths
  length sqliteEvents === length stmEvents
  -- Monotonic ID sequence parity (1 .. N)
  map eventId sqliteEvents === [fromIntegral i | i <- [1 .. eventCount]]
  map eventId stmEvents === [fromIntegral i | i <- [1 .. eventCount]]
  -- Domain payload parity
  map eventType sqliteEvents === map eventType stmEvents
  map eventPayload sqliteEvents === map eventPayload stmEvents
  map eventSessionId sqliteEvents === map eventSessionId stmEvents

-- ----------------------------------------------------------------------------
-- Property 2: TaskQueue Parity (SQLite vs STM)
-- ----------------------------------------------------------------------------

prop_task_queue_parity :: Property
prop_task_queue_parity = property $ do
  taskCount <- forAll $ Gen.int (Range.linear 1 12)
  tasks <- forAll $ Gen.list (Range.singleton taskCount) $ do
    tidStr <- Gen.text (Range.linear 3 10) Gen.alphaNum
    payload <- Gen.bytes (Range.linear 1 40)
    pure (TaskId tidStr, TaskPacket payload)
  let worker = WorkerId "parity-worker"

  (sqliteClaimed, stmClaimed, statuses) <- evalIO $ withTempSqlite $ \tmpPath -> do
    -- Run on SQLite
    (sqRes, sqStatuses) <- withSqliteDatabase tmpPath $ \db -> do
      claimed <- runEff . runTaskQueueSqlite db $ do
        forM_ tasks $ \(tid, pkt) ->
          enqueueTask tid pkt
        let claimAll acc = do
              mPkt <- claimTask worker
              case mPkt of
                Nothing  -> pure (reverse acc)
                Just pkt -> claimAll (pkt : acc)
        claimAll []
      -- Complete some tasks, fail others
      runEff . runTaskQueueSqlite db $ do
        forM_ (zip [0 :: Int ..] tasks) $ \(idx, (tid, _)) ->
          if even idx
            then completeTask tid (TaskSuccess "ok")
            else failTask tid "err"
      stats <- forM tasks $ \(tid, _) -> getTaskStatusSqlite db tid
      pure (claimed, stats)

    -- Run on STM
    stmVar <- newStmTaskQueue
    stmRes <- runEff . runTaskQueueSTM stmVar $ do
      forM_ tasks $ \(tid, pkt) ->
        enqueueTask tid pkt
      let claimAll acc = do
            mPkt <- claimTask worker
            case mPkt of
              Nothing  -> pure (reverse acc)
              Just pkt -> claimAll (pkt : acc)
      claimAll []

    pure (sqRes, stmRes, sqStatuses)

  sqliteClaimed === stmClaimed
  forM_ (zip [0 :: Int ..] statuses) $ \(idx, st) ->
    if even idx
      then st === Just "Completed"
      else st === Just "Failed"

-- ----------------------------------------------------------------------------
-- Property 3: Concurrency & Atomic Leases
-- ----------------------------------------------------------------------------

prop_concurrent_leases :: Property
prop_concurrent_leases = property $ do
  taskCount <- forAll $ Gen.int (Range.linear 10 30)
  workerCount <- forAll $ Gen.int (Range.linear 2 4)

  claimedList <- evalIO $ withTempSqlite $ \tmpPath -> do
    -- Initialize schema and enqueue all tasks
    withSqliteDatabase tmpPath $ \initDb -> do
      forM_ [1 .. taskCount] $ \i -> do
        let tid = TaskId ("task-" <> T.pack (show i))
            pkt = TaskPacket (BSC.pack ("payload-" <> show i))
        enqueueTaskSqlite initDb tid pkt

    -- Concurrently claim tasks across separate worker database handles
    resultsVar <- newMVar ([] :: [TaskPacket])
    doneVars <- replicateM workerCount newEmptyMVar

    forM_ (zip [1 .. workerCount] doneVars) $ \(wIdx, doneVar) -> do
      forkIO $ (`finally` putMVar doneVar ()) $ do
        withExistingSqliteDatabase tmpPath $ \workerDb -> do
          let wid = WorkerId ("worker-" <> T.pack (show wIdx))
              loop = do
                mPkt <- claimTaskSqlite workerDb 300 wid
                case mPkt of
                  Nothing -> pure ()
                  Just pkt -> do
                    modifyMVar_ resultsVar (\pkts -> pure (pkt : pkts))
                    loop
          loop

    -- Await completion of all worker threads
    mapM_ takeMVar doneVars
    readMVar resultsVar

  -- Invariant 1: No duplicate claims across workers (atomic lease verification)
  length claimedList === length (List.nub claimedList)
  -- Invariant 2: Exactly all enqueued tasks were successfully claimed
  length claimedList === taskCount

-- ----------------------------------------------------------------------------
-- Property 4: Event Tail Folds and Stream Replay
-- ----------------------------------------------------------------------------

prop_stream_tail_replay :: Property
prop_stream_tail_replay = property $ do
  totalEvents <- forAll $ Gen.int (Range.linear 5 15)
  tailCount <- forAll $ Gen.int (Range.linear 1 5)
  let sid = SessionId "session-tail"

  (allEvs, tailEvs, foldedSum, replayedEvs) <- evalIO $ withTempSqlite $ \tmpPath -> do
    withSqliteDatabase tmpPath $ \db -> do
      forM_ [1 .. totalEvents] $ \i -> do
        let evType = "event-" <> T.pack (show i)
            payload = BSC.pack ("payload-" <> show i)
        appendEventSqlite db sid evType payload

      allRead <- readEventsSqlite db sid
      tailRead <- readEventsTail db sid tailCount
      fSum <- foldEventsTail db sid tailCount (\acc ev -> acc + eventId ev) (0 :: Int64)
      replayed <- Y.toList_ (replayEventsStream db sid)
      pure (allRead, tailRead, fSum, replayed)

  -- All events read matches total count
  length allEvs === totalEvents
  -- Replay stream matches full read
  replayedEvs === allEvs
  -- Tail read matches the last N elements of all events
  tailEvs === drop (totalEvents - min tailCount totalEvents) allEvs
  -- Tail fold accumulated sum matches the sum of IDs in tail
  foldedSum === sum (map eventId tailEvs)

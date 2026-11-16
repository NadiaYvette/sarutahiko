{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Module      : Yamaarashi.Daemon.PowerAndWAL
-- Description : Linux BAT0 Power Guard & Crash-Only SQLite WAL Turn Ledger
--
-- Hardware battery supervisor and crash-only WAL turn ledger:
-- 1. Polls /sys/class/power_supply/BAT*/{status,capacity}
-- 2. Enforces SoftThrottle (<= 15% and discharging) & HardCheckpoint (<= 7% and discharging)
-- 3. Manages SQLite WAL turn checkpoints with content-addressed Z3 memoization
--    for instantaneous zero-cost crash recovery.
module Yamaarashi.Daemon.PowerAndWAL
  ( -- * Power and Battery Types
    BatteryStatus (..)
  , BatteryState (..)
  , PowerPolicy (..)
  , PowerAction (..)

    -- * Power Supervisor Operations
  , pollBatteryState
  , determinePowerPolicy
  , enforcePowerThrottle

    -- * SQLite WAL Turn Ledger Types
  , TurnWALCheckpoint (..)
  , Z3MemoEntry (..)

    -- * SQLite WAL Operations
  , withWALDatabase
  , initWALSchema
  , checkpointTurnWAL
  , resumeFromWAL
  , memoizeZ3Query
  , lookupZ3Memo
  ) where

import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Database.SQLite3 as SQLite
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))

-- | Hardware battery state reported by Linux sysfs.
data BatteryStatus
  = BatteryCharging
  | BatteryDischarging
  | BatteryFull
  | BatteryNotCharging
  | BatteryUnknown !Text
  deriving stock (Show, Eq)

-- | Battery capacity and status observed from sysfs power_supply.
data BatteryState = BatteryState
  { bsCapacity :: !Int            -- ^ Percentage 0-100
  , bsStatus   :: !BatteryStatus  -- ^ Power supply status
  , bsPath     :: !FilePath       -- ^ Power supply path examined
  } deriving stock (Show, Eq)

-- | Throttle policies based on battery capacity and discharging state.
data PowerPolicy
  = PolicyNormal
  | PolicySoftThrottle   -- ^ <= 15% discharging: halt new sandbox spawns
  | PolicyHardCheckpoint -- ^ <= 7% discharging: serialize in-flight state and clean halt
  deriving stock (Show, Eq)

-- | Concrete actions triggered by the power supervisor.
data PowerAction
  = ActionProceedNormal
  | ActionHaltNewSandboxes
  | ActionTriggerHardCheckpoint
  deriving stock (Show, Eq)

-- | Turn checkpoint persisted in SQLite WAL ledger.
data TurnWALCheckpoint = TurnWALCheckpoint
  { twcTaskId        :: !Text
  , twcTurnIndex     :: !Int
  , twcStateSnapshot :: !Text
  , twcTimestamp     :: !Text
  } deriving stock (Show, Eq)

-- | Content-addressed memoization entry for Z3 subtype queries.
data Z3MemoEntry = Z3MemoEntry
  { z3SigHash       :: !Text
  , z3VcHash        :: !Text
  , z3SubtypeResult :: !Bool
  } deriving stock (Show, Eq)

-- | Poll /sys/class/power_supply/BAT* for capacity and status.
-- Defaults to "/sys/class/power_supply/BAT0" if Nothing is specified.
pollBatteryState :: Maybe FilePath -> IO BatteryState
pollBatteryState mPath = do
  let basePath = case mPath of
        Just p  -> p
        Nothing -> "/sys/class/power_supply/BAT0"
  hasDir <- doesDirectoryExist basePath
  if not hasDir
    then pure (BatteryState 100 BatteryFull basePath)
    else do
      capExists <- doesFileExist (basePath </> "capacity")
      statExists <- doesFileExist (basePath </> "status")
      cap <- if capExists
        then do
          txt <- TIO.readFile (basePath </> "capacity")
          case reads (T.unpack (T.strip txt)) of
            [(c, "")] -> pure c
            _         -> pure 100
        else pure 100
      status <- if statExists
        then do
          txt <- TIO.readFile (basePath </> "status")
          pure $ parseBatteryStatus (T.strip txt)
        else pure (BatteryUnknown "Missing status file")
      pure (BatteryState cap status basePath)

parseBatteryStatus :: Text -> BatteryStatus
parseBatteryStatus txt = case T.toLower txt of
  "charging"     -> BatteryCharging
  "discharging"  -> BatteryDischarging
  "full"         -> BatteryFull
  "not charging" -> BatteryNotCharging
  other          -> BatteryUnknown other

-- | Evaluate policy thresholds:
-- SoftThrottle at <= 15% (Discharging)
-- HardCheckpoint at <= 7% (Discharging)
determinePowerPolicy :: BatteryState -> PowerPolicy
determinePowerPolicy bs
  | bsStatus bs == BatteryDischarging && bsCapacity bs <= 7  = PolicyHardCheckpoint
  | bsStatus bs == BatteryDischarging && bsCapacity bs <= 15 = PolicySoftThrottle
  | otherwise                                                = PolicyNormal

-- | Enforce the determined power policy action.
enforcePowerThrottle :: BatteryState -> IO PowerAction
enforcePowerThrottle bs = pure $ case determinePowerPolicy bs of
  PolicyNormal         -> ActionProceedNormal
  PolicySoftThrottle   -> ActionHaltNewSandboxes
  PolicyHardCheckpoint -> ActionTriggerHardCheckpoint

-- | Open a SQLite connection configured with WAL and synchronous=FULL.
withWALDatabase :: FilePath -> (SQLite.Database -> IO a) -> IO a
withWALDatabase dbPath action = do
  createDirectoryIfMissing True (takeDirectory dbPath)
  bracket (SQLite.open (T.pack dbPath)) SQLite.close $ \db -> do
    SQLite.exec db "PRAGMA journal_mode=WAL;"
    SQLite.exec db "PRAGMA synchronous=FULL;"
    action db

-- | Initialize the WAL turn ledger and Z3 memo tables.
initWALSchema :: FilePath -> IO ()
initWALSchema dbPath = withWALDatabase dbPath $ \db -> do
  SQLite.exec db
    "CREATE TABLE IF NOT EXISTS turn_wal_checkpoints (\
    \  id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \  task_id TEXT NOT NULL,\
    \  turn_index INTEGER NOT NULL,\
    \  state_snapshot TEXT NOT NULL,\
    \  created_at DATETIME DEFAULT CURRENT_TIMESTAMP\
    \);"
  SQLite.exec db
    "CREATE INDEX IF NOT EXISTS idx_turn_wal_task ON turn_wal_checkpoints (task_id, turn_index);"
  SQLite.exec db
    "CREATE TABLE IF NOT EXISTS z3_memo (\
    \  sig_hash TEXT NOT NULL,\
    \  vc_hash TEXT NOT NULL,\
    \  subtype_result INTEGER NOT NULL,\
    \  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,\
    \  PRIMARY KEY (sig_hash, vc_hash)\
    \);"

-- | Persist a granular turn checkpoint into SQLite WAL.
checkpointTurnWAL :: FilePath -> TurnWALCheckpoint -> IO ()
checkpointTurnWAL dbPath cp = withWALDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db
    "INSERT INTO turn_wal_checkpoints (task_id, turn_index, state_snapshot) VALUES (?, ?, ?);"
  SQLite.bind stmt
    [ SQLite.SQLText (twcTaskId cp)
    , SQLite.SQLInteger (fromIntegral (twcTurnIndex cp))
    , SQLite.SQLText (twcStateSnapshot cp)
    ]
  _ <- SQLite.step stmt
  SQLite.finalize stmt

-- | Retrieve the latest turn checkpoint for a task for crash-only recovery.
resumeFromWAL :: FilePath -> Text -> IO (Maybe TurnWALCheckpoint)
resumeFromWAL dbPath tId = withWALDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db
    "SELECT turn_index, state_snapshot, created_at FROM turn_wal_checkpoints WHERE task_id = ? ORDER BY id DESC LIMIT 1;"
  SQLite.bind stmt [SQLite.SQLText tId]
  res <- SQLite.step stmt >>= \case
    SQLite.Row -> do
      turnIdx <- SQLite.column stmt 0 >>= \case
        SQLite.SQLInteger n -> pure (fromIntegral n)
        _                   -> pure 0
      snap <- SQLite.column stmt 1 >>= \case
        SQLite.SQLText t -> pure t
        _                -> pure ""
      ts <- SQLite.column stmt 2 >>= \case
        SQLite.SQLText t -> pure t
        _                -> pure ""
      pure $ Just TurnWALCheckpoint
        { twcTaskId        = tId
        , twcTurnIndex     = turnIdx
        , twcStateSnapshot = snap
        , twcTimestamp     = ts
        }
    _ -> pure Nothing
  SQLite.finalize stmt
  pure res

-- | Content-addressed memoization of a Z3 subtype query.
memoizeZ3Query :: FilePath -> Z3MemoEntry -> IO ()
memoizeZ3Query dbPath entry = withWALDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db
    "INSERT OR REPLACE INTO z3_memo (sig_hash, vc_hash, subtype_result) VALUES (?, ?, ?);"
  SQLite.bind stmt
    [ SQLite.SQLText (z3SigHash entry)
    , SQLite.SQLText (z3VcHash entry)
    , SQLite.SQLInteger (if z3SubtypeResult entry then 1 else 0)
    ]
  _ <- SQLite.step stmt
  SQLite.finalize stmt

-- | Look up a cached Z3 query result.
lookupZ3Memo :: FilePath -> Text -> Text -> IO (Maybe Bool)
lookupZ3Memo dbPath sigH vcH = withWALDatabase dbPath $ \db -> do
  stmt <- SQLite.prepare db
    "SELECT subtype_result FROM z3_memo WHERE sig_hash = ? AND vc_hash = ?;"
  SQLite.bind stmt [SQLite.SQLText sigH, SQLite.SQLText vcH]
  res <- SQLite.step stmt >>= \case
    SQLite.Row -> do
      col <- SQLite.column stmt 0
      case col of
        SQLite.SQLInteger n -> pure (Just (n /= 0))
        _                   -> pure Nothing
    _ -> pure Nothing
  SQLite.finalize stmt
  pure res

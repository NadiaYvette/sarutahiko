{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fplugin=Data.Record.Anon.Plugin #-}

-- |
-- Module      : Hashigakari.Sqlite.Stepper
-- Description : Existential sqlite3_step row stepper and column decoders
--
-- Wraps 'direct-sqlite''s 'sqlite3_step' into the canonical existential
-- 'Stepper IO (Record Identity r)' per HASHIGAKARI_DESIGN.md §3.4 and DECISION-003.
-- Guarantees bracketed statement finalization on short-circuit or stream exhaustion.
module Hashigakari.Sqlite.Stepper
  ( -- * Existential Steppers
    stepRow
  , stepRowIO
  , stepWithDecoder

    -- * Typeclasses for Column Marshalling
  , FromSqlField (..)
  , ToSqlField (..)
  , SqlDecodeError (..)

    -- * Row Decoding Helpers
  , decodeSqlRow
  , readRowMap
  ) where

import Control.Exception (Exception, onException, throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity (..))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Record.Anon (AllFields, K (..), KnownFields, (:.:) (..))
import qualified Data.Record.Anon.Advanced as Anon
import Data.Record.Anon.Advanced
  ( Record
  , cmap
  , reifyKnownFields
  )
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import System.IO.Unsafe (unsafePerformIO)

import qualified Database.SQLite3 as SQLite
import Database.SQLite3 (ColumnIndex (..), SQLData (..), Statement, StepResult (..))

import Sarutahiko.Effect.EventStore (EventId (..), SessionId (..))
import Sarutahiko.Effect.Stepper (Stepper, mkStepper)
import Sarutahiko.Effect.TaskQueue (TaskId (..), TaskPacket (..), TaskResult (..), WorkerId (..))

-- | Error thrown when a row cannot be decoded into the expected 'large-anon' schema.
newtype SqlDecodeError = SqlDecodeError Text
  deriving stock (Eq, Show)

instance Exception SqlDecodeError

-- | Typeclass for decoding SQLite column values into typed Haskell representations.
class FromSqlField a where
  fromSqlField :: Text -> Maybe SQLData -> Either Text a

-- | Typeclass for encoding typed Haskell values into SQLite column values.
class ToSqlField a where
  toSqlField :: a -> SQLData

-- ----------------------------------------------------------------------------
-- Primitive Field Instances
-- ----------------------------------------------------------------------------

instance FromSqlField Int64 where
  fromSqlField _ (Just (SQLInteger n)) = Right n
  fromSqlField name (Just _)          = Left (name <> ": expected SQLInteger")
  fromSqlField name Nothing           = Left (name <> ": column missing")

instance ToSqlField Int64 where
  toSqlField = SQLInteger

instance FromSqlField Int where
  fromSqlField _ (Just (SQLInteger n)) = Right (fromIntegral n)
  fromSqlField name (Just _)          = Left (name <> ": expected SQLInteger for Int")
  fromSqlField name Nothing           = Left (name <> ": column missing")

instance ToSqlField Int where
  toSqlField = SQLInteger . fromIntegral

instance FromSqlField Double where
  fromSqlField _ (Just (SQLFloat d))   = Right d
  fromSqlField _ (Just (SQLInteger n)) = Right (fromIntegral n)
  fromSqlField name (Just _)          = Left (name <> ": expected SQLFloat/SQLInteger for Double")
  fromSqlField name Nothing           = Left (name <> ": column missing")

instance ToSqlField Double where
  toSqlField = SQLFloat

instance FromSqlField Text where
  fromSqlField _ (Just (SQLText t)) = Right t
  fromSqlField _ (Just (SQLBlob b)) = Right (TE.decodeUtf8With TEE.lenientDecode b)
  fromSqlField name (Just _)        = Left (name <> ": expected SQLText/SQLBlob")
  fromSqlField name Nothing         = Left (name <> ": column missing")

instance ToSqlField Text where
  toSqlField = SQLText

instance FromSqlField ByteString where
  fromSqlField _ (Just (SQLBlob b)) = Right b
  fromSqlField _ (Just (SQLText t)) = Right (TE.encodeUtf8 t)
  fromSqlField name (Just _)        = Left (name <> ": expected SQLBlob/SQLText")
  fromSqlField name Nothing         = Left (name <> ": column missing")

instance ToSqlField ByteString where
  toSqlField = SQLBlob

instance FromSqlField Bool where
  fromSqlField _ (Just (SQLInteger n)) = Right (n /= 0)
  fromSqlField name (Just _)          = Left (name <> ": expected SQLInteger for Bool")
  fromSqlField name Nothing           = Left (name <> ": column missing")

instance ToSqlField Bool where
  toSqlField b = SQLInteger (if b then 1 else 0)

instance FromSqlField a => FromSqlField (Maybe a) where
  fromSqlField _ Nothing        = Right Nothing
  fromSqlField _ (Just SQLNull) = Right Nothing
  fromSqlField name (Just val)  = Just <$> fromSqlField name (Just val)

instance ToSqlField a => ToSqlField (Maybe a) where
  toSqlField Nothing  = SQLNull
  toSqlField (Just v) = toSqlField v

instance FromSqlField EventId where
  fromSqlField name v = EventId <$> fromSqlField name v

instance ToSqlField EventId where
  toSqlField (EventId n) = SQLInteger n

instance FromSqlField SessionId where
  fromSqlField name v = SessionId <$> fromSqlField name v

instance ToSqlField SessionId where
  toSqlField (SessionId t) = SQLText t

instance FromSqlField TaskId where
  fromSqlField name v = TaskId <$> fromSqlField name v

instance ToSqlField TaskId where
  toSqlField (TaskId t) = SQLText t

instance FromSqlField WorkerId where
  fromSqlField name v = WorkerId <$> fromSqlField name v

instance ToSqlField WorkerId where
  toSqlField (WorkerId t) = SQLText t

instance FromSqlField TaskPacket where
  fromSqlField name v = TaskPacket <$> fromSqlField name v

instance ToSqlField TaskPacket where
  toSqlField (TaskPacket bs) = SQLBlob bs

instance FromSqlField TaskResult where
  fromSqlField _ (Just (SQLBlob b)) = Right (TaskSuccess b)
  fromSqlField _ (Just (SQLText t)) = Right (TaskSuccess (TE.encodeUtf8 t))
  fromSqlField name (Just _)        = Left (name <> ": expected SQLBlob/SQLText for TaskResult")
  fromSqlField name Nothing         = Left (name <> ": column missing")

-- ----------------------------------------------------------------------------
-- Row Reading and Decoding
-- ----------------------------------------------------------------------------

-- | Read all columns of the current statement row into a map keyed by column name.
readRowMap :: Statement -> IO (Map Text SQLData)
readRowMap stmt = do
  ColumnIndex count <- SQLite.columnCount stmt
  pairs <- traverse (\i -> do
    mName <- SQLite.columnName stmt (ColumnIndex i)
    val <- SQLite.column stmt (ColumnIndex i)
    let colKey = fromMaybe (T.pack ("col" ++ show i)) mName
    pure (colKey, val)
    ) [0 .. count - 1]
  pure (Map.fromList pairs)

-- | Decode a map of column names and values into a 'large-anon' 'Record Identity r'.
decodeSqlRow
  :: forall r. (KnownFields r, AllFields r FromSqlField)
  => Map Text SQLData
  -> Either Text (Record Identity r)
decodeSqlRow rowMap = do
  let namesRecord = reifyKnownFields (Proxy @r)
      decRecord = cmap (Proxy @FromSqlField) (\(K name) ->
        let colKey = T.pack name
            mData = Map.lookup colKey rowMap
        in Comp (Identity <$> fromSqlField colKey mData)
        ) namesRecord
  Anon.sequenceA decRecord

-- ----------------------------------------------------------------------------
-- Stepper Construction & Bracketed Finalization
-- ----------------------------------------------------------------------------

data StepperState = StepperState
  { ssStmt      :: !Statement
  , ssFinalized :: !(IORef Bool)
  }

-- | Atomically finalize the statement exactly once.
closeStepperAction :: StepperState -> IO ()
closeStepperAction st = do
  already <- atomicModifyIORef' (ssFinalized st) (\fin -> (True, fin))
  unless already $
    SQLite.finalize (ssStmt st)

-- | Construct a general Stepper around a SQLite statement with a custom row decoder.
stepWithDecoder
  :: (Statement -> IO a)
  -> Statement
  -> IO (Stepper IO a)
stepWithDecoder decode stmt = do
  ref <- newIORef False
  let st0 = StepperState stmt ref
      stepAct st = do
        isFin <- readIORef (ssFinalized st)
        if isFin
          then pure Nothing
          else do
            res <- SQLite.step (ssStmt st)
            case res of
              Done -> do
                closeStepperAction st
                pure Nothing
              Row -> do
                rowVal <- decode (ssStmt st) `onException` closeStepperAction st
                pure (Just (rowVal, st))
  pure (mkStepper st0 stepAct closeStepperAction)

-- | Construct a 'Stepper IO (Record Identity r)' from a prepared statement in IO.
stepRowIO
  :: forall r. (KnownFields r, AllFields r FromSqlField)
  => Statement
  -> IO (Stepper IO (Record Identity r))
stepRowIO = stepWithDecoder $ \stmt -> do
  rowMap <- readRowMap stmt
  case decodeSqlRow @r rowMap of
    Left err  -> throwIO (SqlDecodeError err)
    Right rec -> pure rec

-- | Canonical existential row stepper wrapping 'direct-sqlite' 'sqlite3_step'.
-- Brackets statement finalization to guarantee resource release on short-circuit.
stepRow
  :: forall r. (KnownFields r, AllFields r FromSqlField)
  => Statement
  -> Stepper IO (Record Identity r)
stepRow stmt = unsafePerformIO (stepRowIO @r stmt)
{-# NOINLINE stepRow #-}

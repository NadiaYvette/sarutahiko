{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : Sarutahiko.Records.Envelope
-- Description : Wire envelopes and unknown-field preservation (E3–E4)
--
-- Enforces unknown-field preservation at the serialization boundary rather
-- than polluting internal record schemas per FIELDS_RECORDS_DESIGN.md §4.
module Sarutahiko.Records.Envelope
  ( -- * Row Categorization
    RowKind (..)

    -- * Wire Envelope (E3–E4)
  , WireEnvelope (..)
  , mkWireEnvelope

    -- * Re-Serialization Guards (E4)
  , ForwardBoundaryViolation (..)
  , canReserialize
  , assertCanReserialize
  ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

import Sarutahiko.Fields.Datum (SchemaVersion)

-- | High-level categorization of record payloads across the agent lifecycle.
data RowKind
  = RowKindEvent
    -- ^ Skinny Spine append-only event
  | RowKindTurn
    -- ^ LLM context turn or prompt structure
  | RowKindCommand
    -- ^ MCP or CLI tool invocation
  | RowKindLog
    -- ^ Structured telemetry / observability record
  | RowKindCustom !Text
    -- ^ Custom user or plugin domain
  deriving stock (Eq, Show)

-- | Wire envelope preserving unparsed raw bytes and unknown fields across schema boundaries (E3).
--
-- Satisfies contracts:
-- - E3: Reader ignores unknown fields while deserializing recognized fields into 'envPayload'.
-- - E4: Forward boundary guard prevents silent dropping of unknown fields during re-serialization.
-- - Hash stability: 'envRawBytes' guarantees exact byte-for-byte fidelity for 'kakegoe' prefix caching.
data WireEnvelope a = WireEnvelope
  { envKind            :: !RowKind
  , envSchemaVersion   :: !SchemaVersion
    -- ^ Target schema version of the parsed payload.
  , envOriginalVersion :: !SchemaVersion
    -- ^ E6: The schema version in effect when the wire payload was originally authored.
  , envPayload         :: !a
    -- ^ Parsed, strongly typed payload (e.g. 'Record Identity r').
  , envRawBytes        :: !ByteString
    -- ^ Exact, unmodified wire bytes for hash determinism and passthrough routing.
  , envUnknownFields   :: !(Map Text Text)
    -- ^ Unparsed extraneous fields preserved for forward compatibility.
  } deriving stock (Eq, Show, Functor)

-- | Constructor for creating a 'WireEnvelope'.
mkWireEnvelope
  :: RowKind
  -> SchemaVersion
  -> SchemaVersion
  -> a
  -> ByteString
  -> Map Text Text
  -> WireEnvelope a
mkWireEnvelope = WireEnvelope

-- | Exception thrown when an intermediary running an older schema attempts to
-- re-serialize a payload that originated from a newer forward schema version (E4).
data ForwardBoundaryViolation = ForwardBoundaryReserializationForbidden
  { fwdLocalVersion    :: !SchemaVersion
  , fwdEnvelopeVersion :: !SchemaVersion
  } deriving stock (Eq, Show)

instance Exception ForwardBoundaryViolation

-- | Check whether the local system may safely re-serialize the payload.
--
-- Re-serialization is permitted only if the payload was authored by a schema version
-- less than or equal to the local system's version (E4).
canReserialize :: SchemaVersion -> WireEnvelope a -> Bool
canReserialize localVer env = envOriginalVersion env <= localVer

-- | Enforce the E4 forward-boundary re-serialization guard.
assertCanReserialize
  :: SchemaVersion
  -> WireEnvelope a
  -> Either ForwardBoundaryViolation ()
assertCanReserialize localVer env
  | canReserialize localVer env = Right ()
  | otherwise =
      Left $ ForwardBoundaryReserializationForbidden
        { fwdLocalVersion    = localVer
        , fwdEnvelopeVersion = envOriginalVersion env
        }

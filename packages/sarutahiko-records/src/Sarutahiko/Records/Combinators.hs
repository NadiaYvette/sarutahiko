{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Sarutahiko.Records.Combinators
-- Description : Row combinators and the right-biased override operator (⊕)
--
-- Exposes the row algebra and merge combinators satisfying the algebraic
-- laws L1–L6 per FIELDS_RECORDS_DESIGN.md §5.
module Sarutahiko.Records.Combinators
  ( -- * The Override Merge Operator
    (⊕)

    -- * Record Transformation Combinators
  , mapRecord
  , cmapRecord
  , zipWithRecord
  , traverseRecord
  , projectRecord
  , getRecordField
  , setRecordField
  , emptyRecord
  ) where

import Data.Proxy (Proxy)
import Data.Record.Anon (AllFields, Field, Merge, RowHasField, SubRow)
import Data.Record.Anon.Advanced (Record)
import qualified Data.Record.Anon.Advanced as Anon

-- | Right-biased record merge operator (⊕) satisfying laws L1–L6.
--
-- In 'large-anon', 'Anon.merge' is left-biased (the first argument shadows the second).
-- Therefore, to achieve right-biased override semantics where 'r2' overrides 'r1' per
-- FIELDS_RECORDS_DESIGN.md §5.3, '(⊕)' is defined as 'flip Anon.merge'.
--
-- - L1 (Associativity): (a ⊕ b) ⊕ c = a ⊕ (b ⊕ c)
-- - L2 (Left Identity): ∅ ⊕ a = a
-- - L3 (Right Identity): a ⊕ ∅ = a
-- - L4 (Idempotence): a ⊕ a = a
-- - L5 (Right Precedence): Fields in the right record override corresponding fields in the left.
-- - L6 (Projection Distribution): Sub-row projections distribute cleanly over merges.
(⊕) :: Record f r1 -> Record f r2 -> Record f (Merge r2 r1)
(⊕) = flip Anon.merge

infixr 5 ⊕

-- | Map a natural transformation across all fields of a record.
mapRecord :: (forall x. f x -> g x) -> Record f r -> Record g r
mapRecord = Anon.map

-- | Map a constrained natural transformation across all fields of a record.
cmapRecord
  :: AllFields r c
  => Proxy c
  -> (forall x. c x => f x -> g x)
  -> Record f r
  -> Record g r
cmapRecord = Anon.cmap

-- | Pairwise applicative zip across two records with identical row schemas.
zipWithRecord
  :: (forall x. f x -> g x -> h x)
  -> Record f r
  -> Record g r
  -> Record h r
zipWithRecord = Anon.zipWith

-- | Effectful traversal over record fields.
traverseRecord
  :: Applicative m
  => (forall x. f x -> m (g x))
  -> Record f r
  -> m (Record g r)
traverseRecord = Anon.mapM

-- | Project a sub-row out of a larger record.
projectRecord :: SubRow r sub => Record f r -> Record f sub
projectRecord = Anon.project

-- | Retrieve a field value from a record.
getRecordField :: RowHasField n r a => Field n -> Record f r -> f a
getRecordField = Anon.get

-- | Update a field value in a record.
setRecordField :: RowHasField n r a => Field n -> f a -> Record f r -> Record f r
setRecordField = Anon.set

-- | The canonical empty record.
emptyRecord :: Record f '[]
emptyRecord = Anon.empty

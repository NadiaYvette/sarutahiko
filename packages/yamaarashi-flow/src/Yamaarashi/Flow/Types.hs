{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Yamaarashi.Flow.Types
-- Description : Selective workflow AST and DAG types
--
-- Models task nodes, dependency graphs over 'algebraic-graphs', content-addressed
-- cache keys, determinism tags, and the 'Flow' selective applicative functor
-- per YAMAARASHI_DESIGN.md §1-§2.
module Yamaarashi.Flow.Types
  ( -- * Task Identifiers & Cache Keys
    TaskId (..)
  , CacheKey (..)
  , VFSLocation (..)
  , TaskPurity (..)
    -- * Task Node & Graph
  , TaskNode (..)
  , TaskGraph
  , buildGraph
    -- * Selective Flow Functor
  , Flow (..)
  , task
  , extractNodes
  ) where

import Algebra.Graph (Graph)
import qualified Algebra.Graph as G
import Control.Selective (Selective (..))
import Data.ByteString (ByteString)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Sarutahiko.Effect.TaskQueue (TaskId (..))

-- | Content-addressed cryptographic cache key (e.g. SHA-256 over task specification & inputs).
newtype CacheKey = CacheKey { unCacheKey :: ByteString }
  deriving stock (Eq, Ord, Show)

-- | Virtual file-system location at '$_' namespace (e.g. '$_/build/binary').
newtype VFSLocation = VFSLocation { unVFSLocation :: Text }
  deriving stock (Eq, Ord, Show)

-- | Determinism and caching policy for workflow tasks.
data TaskPurity
  = Deterministic
  -- ^ Strictly deterministic; output depends solely on task inputs and can be indefinitely cached.
  | Stochastic !CacheKey
  -- ^ May produce differing outputs (e.g. non-zero temperature LLM calls); only valid when cache key matches.
  deriving stock (Eq, Ord, Show)

-- | Individual node in the task execution graph.
data TaskNode = TaskNode
  { nodeId           :: !TaskId
  , nodeName         :: !Text
  , nodePurity       :: !TaskPurity
  , nodeDependencies :: !(Set TaskId)
  , nodeLocation     :: !(Maybe VFSLocation)
  } deriving stock (Eq, Ord, Show)

-- | Algebraic graph of task nodes.
type TaskGraph = Graph TaskNode

-- | Construct a 'TaskGraph' from a collection of 'TaskNode's, establishing edges
-- from each dependency to the dependent node.
buildGraph :: [TaskNode] -> TaskGraph
buildGraph nodes = G.overlay vertices edges
  where
    vertices = G.vertices nodes
    nodeMap = [ (nodeId n, n) | n <- nodes ]
    findNode tid = lookup tid nodeMap
    edges = G.edges
      [ (depNode, n)
      | n <- nodes
      , depId <- Set.toList (nodeDependencies n)
      , Just depNode <- [findNode depId]
      ]

-- | Selective Applicative Functor representing macro-task workflow computation.
--
-- Free over task actions in base monad @m@.
data Flow m a where
  Pure   :: a -> Flow m a
  Action :: !TaskNode -> m a -> Flow m a
  Ap     :: Flow m (a -> b) -> Flow m a -> Flow m b
  Select :: Flow m (Either a b) -> Flow m (a -> b) -> Flow m b

instance Functor (Flow m) where
  fmap f (Pure a) = Pure (f a)
  fmap f x        = Ap (Pure f) x

instance Applicative (Flow m) where
  pure = Pure
  (<*>) = Ap

instance Selective (Flow m) where
  select = Select

-- | Construct a leaf task in the workflow.
task :: TaskNode -> m a -> Flow m a
task = Action

-- | Statically extract all 'TaskNode' declarations from a workflow without executing any IO.
extractNodes :: Flow m a -> Set TaskNode
extractNodes = \case
  Pure _     -> Set.empty
  Action n _ -> Set.singleton n
  Ap f x     -> extractNodes f <> extractNodes x
  Select x f -> extractNodes x <> extractNodes f

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Raft.Metrics
( RaftNodeMetrics
, getMetricsStore
, getRaftNodeMetrics
, incrInvalidCmdCounter
, incrEventsHandledCounter
) where

import Protolude

import qualified Control.Monad.Metrics as Metrics
import qualified Control.Monad.Metrics.Internal as Metrics

import qualified Data.HashMap.Strict as HashMap
import Data.Serialize (Serialize)

import qualified System.Metrics as EKG

------------------------------------------------------------------------------
-- Raft Node Metrics
------------------------------------------------------------------------------

data RaftNodeMetrics
  = RaftNodeMetrics
  { invalidCmdCounter :: Int64
  , eventsHandledCounter :: Int64
  } deriving (Show, Generic, Serialize)

getMetricsStore :: (MonadIO m, Metrics.MonadMetrics m) => m EKG.Store
getMetricsStore = Metrics._metricsStore <$> Metrics.getMetrics

getRaftNodeMetrics :: (MonadIO m, Metrics.MonadMetrics m) => m RaftNodeMetrics
getRaftNodeMetrics = do
  metricsStore <- getMetricsStore
  sample <- liftIO (EKG.sampleAll metricsStore)
  pure RaftNodeMetrics
    { invalidCmdCounter = lookupCounterValue InvalidCmdCounter sample
    , eventsHandledCounter = lookupCounterValue EventsHandledCounter sample
    }

lookupCounterValue :: RaftNodeCounter -> EKG.Sample -> Int64
lookupCounterValue counter sample =
  case HashMap.lookup (show InvalidCmdCounter) sample of
    Nothing -> 0
    Just (EKG.Counter n) -> n
    -- TODO Handle failure in a better way?
    Just _ -> 0

data RaftNodeCounter
  = InvalidCmdCounter
  | EventsHandledCounter
  deriving Show

incrRaftNodeCounter :: (MonadIO m, Metrics.MonadMetrics m) => RaftNodeCounter -> m ()
incrRaftNodeCounter = Metrics.increment . show

incrInvalidCmdCounter :: (MonadIO m, Metrics.MonadMetrics m) => m ()
incrInvalidCmdCounter = incrRaftNodeCounter InvalidCmdCounter

incrEventsHandledCounter :: (MonadIO m, Metrics.MonadMetrics m) => m ()
incrEventsHandledCounter = incrRaftNodeCounter EventsHandledCounter

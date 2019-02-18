

module Raft.Config where

import Protolude

import Numeric.Natural (Natural)

import Raft.Types

-- | Configuration of a node in the cluster
data RaftNodeConfig = RaftNodeConfig
  { configNodeId :: NodeId -- ^ Node id of the running node
  , configNodeIds :: NodeIds -- ^ Set of all other node ids in the cluster
  , configElectionTimeout :: (Natural, Natural) -- ^ Range of times an election timeout can take
  , configHeartbeatTimeout :: Natural -- ^ Heartbeat timeout timer
  , configStorageState :: StorageState -- ^ Create a fresh DB or read from existing
  } deriving (Show)

data StorageState = New | Existing
  deriving Show

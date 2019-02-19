{-# LANGUAGE GADTs #-}
module TestRaft where
import Protolude

import Control.Monad.Catch
import Data.Sequence (Seq(..), (><), dropWhileR, (!?), singleton,)
import qualified Data.Sequence as Seq
import qualified Data.Map as Map
import Test.Tasty

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad


import RaftTestT
import TestUtils

idx1 = Entry (Index 1)
      (Term 1)
      (EntryValue (Set "x" 1))
      (ClientIssuer client0 (SerialNum 1))
      genesisHash

idx2 = Entry (Index 2)
      (Term 2)
      (EntryValue (Set "x" 2))
      (ClientIssuer client0 (SerialNum 1))
      (hashEntry idx1)

idx3 = Entry (Index 3)
      (Term 3)
      (EntryValue (Set "x" 3))
      (ClientIssuer client0 (SerialNum 1))
      (hashEntry idx2)

idx3' = Entry (Index 3)
        (Term 3)
        (EntryValue (Set "x" 0))
        (ClientIssuer client0 (SerialNum 1))
        (hashEntry idx2)

concurrentRaftTest :: (TestEventChans IO -> TestClientRespChans IO -> IO a) -> IO a
concurrentRaftTest runTest =
    Control.Monad.Catch.bracket setup teardown $
      uncurry runTest . snd
  where
    setup = do
      (eventChans, clientRespChans) <- initTestChanMaps
      let (testNodeEnvs, testNodeStates) = initRaftTestEnvs eventChans clientRespChans
      let testNodeStates = Map.adjust (addInitialEntries $ Seq.fromList [idx1, idx2, idx3]) node0 testNodeStates
      let testNodeStates = Map.adjust (addInitialEntries $ Seq.fromList [idx1, idx2, idx3']) node1 testNodeStates
      let testNodeStates = Map.adjust (addInitialEntries $ Seq.fromList [idx1, idx2]) node2 testNodeStates
      tids <- forkTestNodes testNodeEnvs testNodeStates
      pure (tids, (eventChans, clientRespChans))
    teardown = mapM_ killThread . fst

    addInitialEntries :: Entries StoreCmd -> TestNodeState ->  TestNodeState
    addInitialEntries entries nodeState = nodeState {testNodeLog = entries}


followerCatchup :: TestEventChans IO -> TestClientRespChans IO -> IO Store
followerCatchup eventChans clientRespChans =
  runRaftTestClientT client0 client0RespChan eventChans $ do
    leaderElection'' node0
    Right store <- syncClientRead node0
    pure store
  where
    leaderElection'' nid = leaderElection' nid eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

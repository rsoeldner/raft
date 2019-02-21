{-# LANGUAGE GADTs #-}
module TestRaft where
import Protolude

import Control.Monad.Catch
import Control.Concurrent.Classy.STM.TVar
import Data.Sequence (Seq(..), (><), dropWhileR, (!?), singleton,)
import qualified Data.Sequence as Seq
import qualified Data.Map as Map
import Test.Tasty.HUnit
import Test.Tasty

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad

import RaftTestT
import TestUtils

idx1, idx2, idx3, idx3' :: Entry StoreCmd
idx1 = Entry (Index 1)
      (Term 1)
      NoValue
      (LeaderIssuer (LeaderId node0))
      --(ClientIssuer client0 (SerialNum 0))
      genesisHash

idx2 = Entry (Index 2)
      (Term 2)
      NoValue
      (LeaderIssuer (LeaderId node0))
      (hashEntry idx1)

idx3 = Entry (Index 3)
      (Term 3)
      NoValue
      (LeaderIssuer (LeaderId node0))
      (hashEntry idx2)

idx3' = Entry (Index 3)
        (Term 3)
        NoValue
      (LeaderIssuer (LeaderId node1))
        (hashEntry idx2)

concurrentRaftTest :: (TestEventChans IO -> TestClientRespChans IO -> IO a) -> IO a
concurrentRaftTest runTest =
    Control.Monad.Catch.bracket setup teardown $
      uncurry runTest . snd
  where
    setup = do
      (eventChans, clientRespChans) <- initTestChanMaps
      testNodeStatesTVar <- initTestStates
      testNodeEnvs <- initRaftTestEnvs eventChans clientRespChans testNodeStatesTVar
      --let testNodeStates' = Map.adjust (addInitialEntries (Seq.fromList [idx1, idx2, idx3]) (Term 3)) node0 testNodeStates
      --let testNodeStates''  = Map.adjust (addInitialEntries (Seq.fromList [idx1, idx2, idx3']) (Term 3)) node1 testNodeStates'
      --let testNodeStates''' = Map.adjust (addInitialEntries (Seq.fromList [idx1, idx2]) (Term 2)) node2 testNodeStates''
      tids <- forkTestNodes testNodeEnvs
      pure (tids, (eventChans, clientRespChans, testNodeEnvs ))
    teardown = mapM_ killThread . fst

    addInitialEntries :: Entries StoreCmd -> Term -> TestNodeState ->  TestNodeState
    addInitialEntries entries term nodeState = nodeState {testNodeLog = entries, testNodePersistentState = PersistentState {currentTerm=term, votedFor=Nothing}}

followerCatchup :: TestEventChans IO -> TestClientRespChans IO -> TVar (STM IO) TestNodeStates -> IO ()
followerCatchup eventChans clientRespChans testNodeStatesTVar =
  runRaftTestClientT client0 client0RespChan eventChans $ do
    leaderElection'' node0
    Right store0 <- syncClientRead node0
    --testNodeStates <- get
    pure ()
  where
    leaderElection'' nid = leaderElection' nid eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

test_asd = testCase "wowo" $ do
  a <- concurrentRaftTest followerCatchup
  assertEqual "a" a ()

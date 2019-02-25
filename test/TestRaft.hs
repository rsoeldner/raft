{-# LANGUAGE GADTs #-}
module TestRaft where
import Protolude hiding
  (STM, TVar, TChan, newTChan, readMVar, readTChan, writeTChan, atomically, killThread, ThreadId, readTVar, writeTVar)


import Control.Monad.Catch
import Control.Monad.Conc.Class
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
import Raft.Types

import RaftTestT
import TestUtils

--idx1, idx2, idx3, idx3' :: Entry StoreCmd
--idx1 = Entry (Index 1)
      --(Term 1)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx2 = Entry (Index 2)
      --(Term 2)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx3 = Entry (Index 3)
      --(Term 3)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx3' = Entry (Index 3)
        --(Term 3)
        --(EntryValue $ Set "x" 2)
        --(LeaderIssuer (LeaderId node1))
        --genesisHash

genEntries :: Integer -> Integer -> [Entry StoreCmd]
genEntries numTerms numEntriesPerTerm =
  fmap gen (zip indexes terms)
 where
  indexes = [1 .. numTerms * numEntriesPerTerm]
  terms = concatMap (replicate (fromInteger numEntriesPerTerm)) [1 .. numTerms]
  gen (i, t) = Entry (Index (fromInteger i))
                     (Term (fromInteger t))
                     NoValue
                     (LeaderIssuer (LeaderId node0))
                     genesisHash

concurrentRaftTest :: (TestEventChans IO -> TestClientRespChans IO -> TVar (STM IO) TestNodeStates -> IO a) -> IO a
concurrentRaftTest runTest =
    Control.Monad.Catch.bracket setup teardown $ \(a, (b, c, d)) -> runTest b c d
  where
    setup = do
      (eventChans, clientRespChans) <- initTestChanMaps
      testNodeStatesTVar <- initTestStates
      atomically $ modifyTVar' testNodeStatesTVar $
        \testNodeStates ->
          let entries = genEntries 4 3 -- 4 terms, each with 3 entries
              entriesMutated = fmap
                (\e -> if entryIndex e == Index 12
                  then e { entryIssuer = LeaderIssuer (LeaderId node1)
                         , entryValue  = EntryValue $ Set "x" 2
                         }
                  else e
                )
                entries
              -- Node0 is the leader, is most up to date
              t1 = Map.adjust (addInitialEntries (Seq.fromList entries) (Term 4)) node0 testNodeStates
              -- Node1 has
              t2 = Map.adjust (addInitialEntries (Seq.fromList (entriesMutated)) (Term 4)) node1 t1
              -- Node2 is behind 2 terms
              t3 = Map.adjust (addInitialEntries (Seq.fromList (take 4 entries)) (Term 2)) node2 t2
          in t3

      let testNodeEnvs = initRaftTestEnvs eventChans clientRespChans testNodeStatesTVar
      tids <- forkTestNodes testNodeEnvs
      pure (tids, (eventChans, clientRespChans, testNodeStatesTVar ))
    teardown = mapM_ killThread . fst

    addInitialEntries :: Entries StoreCmd -> Term -> TestNodeState ->  TestNodeState
    addInitialEntries entries term nodeState = nodeState {testNodeLog = entries, testNodePersistentState = PersistentState {currentTerm=term, votedFor=Nothing}}

followerCatchup
  :: TestEventChans IO
  -> TestClientRespChans IO
  -> TVar (STM IO) TestNodeStates
  -> IO (Maybe TestNodeState, Maybe TestNodeState, Maybe TestNodeState)
followerCatchup eventChans clientRespChans testNodeStatesTVar =
  runRaftTestClientT client0 client0RespChan eventChans $ do
    lift $ heartbeat (eventChans Map.! node0)
    lift $ heartbeat (eventChans Map.! node1)
    lift $ heartbeat (eventChans Map.! node2)
    leaderElection'' node0
    testNodeStates <- lift $ atomically $ readTVar testNodeStatesTVar
    liftIO $ Protolude.threadDelay 3000000
    pure
      ( Map.lookup node0 testNodeStates
      , Map.lookup node1 testNodeStates
      , Map.lookup node2 testNodeStates
      )
 where
  leaderElection'' nid = leaderElection' nid eventChans
  Just client0RespChan = Map.lookup client0 clientRespChans

test_followerCatchup = testCase "Follower Catchup" $ do
  (t1, t2, t3) <- concurrentRaftTest followerCatchup
  assertEqual "node behind is caught up" t1 t3
  assertEqual "node with conflict is updated correctly" t1 t2

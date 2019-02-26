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
        --


entries, entriesMutated :: Entries StoreCmd
entries = genEntries 4 3  -- 4 terms, each with 3 entries

entriesMutated = fmap
  (\e -> if entryIndex e == Index 12
    then e { entryIssuer = LeaderIssuer (LeaderId node1)
           , entryValue  = EntryValue $ Set "x" 2
           }
    else e
  )
  entries


electLeaderAndWait eventChans _ = do
    leaderElection' node0
    liftIO $ Protolude.threadDelay 1000000


test_handleAppendEntries = testCase "Follower Catchup" $ do
  let startingNodeStates =  initTestNodeStates [(node0, Term 4, entries), (node1, Term 1, Seq.take 2 entries)]

  (res, endingNodeStates) <- raftTestHarness startingNodeStates $ electLeaderAndWait
  assertTestNodeStatesAllEqual endingNodeStates

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
import SampleEntries



test_AEFollowerBehindN = testCase "Follower behind" $ do
  testStates <- logMatchingTest
    [ (node0, Term 4, entries)
    , (node1, Term 2, Seq.take 2 entries)
    , (node2, Term 4, entries)
    ]
  assertTestNodeStatesAllEqual (Term 5) testStates



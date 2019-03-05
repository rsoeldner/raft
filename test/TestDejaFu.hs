{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module TestDejaFu where

import Protolude hiding
  (STM, TChan, TVar, newTChan, readMVar, readTChan, writeTChan, atomically, killThread, ThreadId)

import Data.Sequence (Seq(..), (><), dropWhileR, (!?))
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Maybe as Maybe
import qualified Data.Serialize as S
import Numeric.Natural
import Test.QuickCheck
import Control.Monad.Fail
import Control.Monad.Catch
import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM.TVar
import Control.Concurrent.Classy.STM.TChan

import Test.DejaFu hiding (get, ThreadId)
import Test.DejaFu.Internal (Settings(..))
import Test.DejaFu.Conc hiding (ThreadId)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.DejaFu hiding (get)

import System.Random (mkStdGen, newStdGen)
import Data.Time.Clock.System (getSystemTime)
import Data.List
import TestUtils
import RaftTestT
import qualified SampleEntries

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad

dejaFuSettings = defaultSettings { _way = randomly (mkStdGen 42) 100 }

test_concurrency :: [TestTree]
test_concurrency =
    [ testGroup "Leader Election" [ testConcurrentProps (leaderElection node0) mempty ]
    , testGroup "increment(set('x', 41)) == x := 42"
        [ testConcurrentProps incrValue (Map.fromList [("x", 42)], Index 3) ]
    , testGroup "set('x', 0) ... 10x incr(x) == x := 10"
        [ testConcurrentProps multIncrValue (Map.fromList [("x", 10)], Index 12) ]
    , testGroup "Follower redirect with no leader" [ testConcurrentProps followerRedirNoLeader NoLeader ]
    , testGroup "Follower redirect with leader" [ testConcurrentProps followerRedirLeader (CurrentLeader (LeaderId node0)) ]
    , testGroup "New leader election" [ testConcurrentProps newLeaderElection (CurrentLeader (LeaderId node1)) ]
    , testGroup "Comprehensive"
        [ testConcurrentProps comprehensive (Index 14, Map.fromList [("x", 9), ("y", 6), ("z", 42)], CurrentLeader (LeaderId node0)) ]
    ]

testConcurrentProps
  :: (Eq a, Show a)
  => RaftTestClientT ConcIO a
  -> a
  -> TestTree
testConcurrentProps test expected =
  testDejafusWithSettings dejaFuSettings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    , ("Success", alwaysTrue (== Right expected))
    ] $ fst <$> withRaftTestNodes emptyTestStates test

leaderElection
  :: NodeId
  -> RaftTestClientM Store
leaderElection nid = leaderElection' nid

incrValue :: RaftTestClientM (Store, Index)
incrValue = do
  leaderElection' node0
  Right idx <- do
    syncClientWrite node0 (Set "x" 41)
    syncClientWrite node0 (Incr "x")
  Right store <- syncClientRead node0
  pure (store, idx)

multIncrValue :: RaftTestClientM (Store, Index)
multIncrValue = do
    leaderElection' node0
    syncClientWrite node0 (Set "x" 0)
    Right idx <-
      fmap (Maybe.fromJust . lastMay) $
        replicateM 10 $ syncClientWrite node0 (Incr "x")
    store <- pollForReadResponse node0
    pure (store, idx)

leaderRedirect :: RaftTestClientM CurrentLeader
leaderRedirect = do
    Left resp <- syncClientWrite node1 (Set "x" 42)
    pure resp

followerRedirNoLeader :: RaftTestClientM CurrentLeader
followerRedirNoLeader = leaderRedirect

followerRedirLeader :: RaftTestClientM CurrentLeader
followerRedirLeader = do
    leaderElection' node0
    leaderRedirect

newLeaderElection :: RaftTestClientM CurrentLeader
newLeaderElection = do
    leaderElection' node0
    leaderElection' node1
    leaderElection' node2
    leaderElection' node1
    Left ldr <- syncClientRead node0
    pure ldr

comprehensive :: RaftTestClientT ConcIO (Index, Store, CurrentLeader)
comprehensive = do
    leaderElection' node0
    Right idx2 <- syncClientWrite node0 (Set "x" 7)
    Right idx3 <- syncClientWrite node0 (Set "y" 3)
    Left (CurrentLeader _) <- syncClientWrite node1 (Incr "y")
    Right _ <- syncClientRead node0

    leaderElection' node1
    Right idx5 <- syncClientWrite node1 (Incr "x")
    Right idx6 <- syncClientWrite node1 (Incr "y")
    Right idx7 <- syncClientWrite node1 (Set "z" 40)
    Left (CurrentLeader _) <- syncClientWrite node2 (Incr "y")
    Right _ <- syncClientRead node1

    leaderElection' node2
    Right idx9 <- syncClientWrite node2 (Incr "z")
    Right idx10 <- syncClientWrite node2 (Incr "x")
    Left _ <- syncClientWrite node1 (Set "q" 100)
    Right idx11 <- syncClientWrite node2 (Incr "y")
    Left _ <- syncClientWrite node0 (Incr "z")
    Right idx12 <- syncClientWrite node2 (Incr "y")
    Left (CurrentLeader _) <- syncClientWrite node0 (Incr "y")
    Right _ <- syncClientRead node2

    leaderElection' node0
    Right idx14 <- syncClientWrite node0 (Incr "z")
    Left (CurrentLeader _) <- syncClientWrite node1 (Incr "y")

    Right store <- syncClientRead node0
    Left ldr <- syncClientRead node1

    pure (idx14, store, ldr)


-- | Check if the majority of the node states are equal after running the given RaftTestClientM
-- program
-- TODO hardcoded to running with 3 nodes
majorityNodeStatesEqual :: RaftTestClientM a -> TestNodeStatesConfig -> TestTree
majorityNodeStatesEqual clientTest startingStatesConfig  =
  testDejafusWithSettings dejaFuSettings
    [ ("No deadlocks", deadlocksNever)
    , ("No exceptions", exceptionsNever)
    , ("Correct", alwaysTrue correctResult)
    ] runTest
  where
    runTest :: ConcIO TestNodeStates
    runTest = do
      let startingNodeStates = initTestStates startingStatesConfig
      (res, endingNodeStates) <- withRaftTestNodes startingNodeStates $ do
        leaderElection' node0
        clientTest
      --(res, endingNodeStates) <- withRaftTestNodes startingNodeStates $ do
        --clientTest
      pure endingNodeStates

    correctResult :: Either Condition TestNodeStates -> Bool
    correctResult (Right testStates) =
      let (inAgreement, inDisagreement) = partition
            (== testNodeLog (testStates Map.! node0))
            (fmap testNodeLog $ Map.elems testStates)
      in  length inAgreement > length inDisagreement
    correctResult (Left _) = False

test_AEFollower :: TestTree
test_AEFollower = majorityNodeStatesEqual (syncClientWrite node0 (Set "x" 7))
  [ (node0, Term 4, SampleEntries.entries)
  , (node1, Term 4, SampleEntries.entries)
  , (node2, Term 4, SampleEntries.entries)
  ]

test_AEFollowerBehindOneTerm :: TestTree
test_AEFollowerBehindOneTerm = majorityNodeStatesEqual (pure ())
  [ (node0, Term 4, SampleEntries.entries)
  , (node1, Term 3, Seq.take 10 SampleEntries.entries)
  , (node2, Term 4, SampleEntries.entries)
  ]

test_AEFollowerBehindMultipleTerms :: TestTree
test_AEFollowerBehindMultipleTerms = majorityNodeStatesEqual (pure ())
--test_AEFollowerBehindMultipleTerms = majorityNodeStatesEqual (leaderElection' node0)
  [ (node0, Term 4, SampleEntries.entries)
  , (node1, Term 2, Seq.take 5 SampleEntries.entries)
  , (node2, Term 4, SampleEntries.entries)
  ]

--prop_AEFollowerBehind :: Small (Positive Integer) -> Small (Positive Integer) -> Bool
--prop_AEFollowerBehind (Small (Positive numEntriesPerTerm)) numTerms = majorityNodeStatesEqual (leaderElection' node0)
    --[ (node0, Term 4, entries)
    --, (node1, Term 2, entries)
    --, (node2, Term 4, entries)
    --]
  --where
    --entries = SampleEntries.genEntries numEntriesPerTerm numTerms


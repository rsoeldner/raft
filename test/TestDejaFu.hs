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

import TestUtils
import RaftTestT

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad


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
  => (TestEventChans ConcIO -> TVar (STM ConcIO) TestNodeStates -> RaftTestClientT ConcIO a)
  -> a
  -> TestTree
testConcurrentProps test expected =
  testDejafusWithSettings settings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    , ("Success", alwaysTrue (== Right expected))
    ] $ fst <$> raftTestHarness emptyTestStates test
  where
    settings = defaultSettings
      { _way = randomly (mkStdGen 42) 100
      }

leaderElection
  :: (MonadConc m, MonadIO m, MonadFail m)
  => NodeId
  -> TestEventChans m
  -> TVar (STM m) TestNodeStates
  -> RaftTestClientT m Store
leaderElection nid eventChans testNodeStatesTVar = leaderElection' nid

incrValue, multIncrValue
  :: (MonadConc m, MonadIO m, MonadFail m)
  => TestEventChans m
  -> TVar (STM m) TestNodeStates
  -> RaftTestClientT m (Store, Index)
incrValue _ _ = do
  leaderElection' node0
  Right idx <- do
    syncClientWrite node0 (Set "x" 41)
    syncClientWrite node0 (Incr "x")
  Right store <- syncClientRead node0
  pure (store, idx)

multIncrValue _ _ = do
    leaderElection' node0
    syncClientWrite node0 (Set "x" 0)
    Right idx <-
      fmap (Maybe.fromJust . lastMay) $
        replicateM 10 $ syncClientWrite node0 (Incr "x")
    store <- pollForReadResponse node0
    pure (store, idx)

leaderRedirect, followerRedirNoLeader, followerRedirLeader, newLeaderElection
  :: (MonadConc m, MonadIO m, MonadFail m)
  => TestEventChans m
  -> TVar (STM m) TestNodeStates
  -> RaftTestClientT m CurrentLeader
leaderRedirect _ _ = do
    Left resp <- syncClientWrite node1 (Set "x" 42)
    pure resp

followerRedirNoLeader = leaderRedirect
followerRedirLeader eventChans testNodeStatesTVar = do
    leaderElection' node0
    leaderRedirect eventChans testNodeStatesTVar

newLeaderElection eventChans _ = do
    leaderElection' node0
    leaderElection' node1
    leaderElection' node2
    leaderElection' node1
    Left ldr <- syncClientRead node0
    pure ldr

comprehensive :: TestEventChans ConcIO -> TVar (STM ConcIO) TestNodeStates -> RaftTestClientT ConcIO (Index, Store, CurrentLeader)
comprehensive _ _ = do
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


entries, entriesMutated :: Entries StoreCmd
entries = genEntries 4 3  -- 4 terms, each with 3 entries

entriesMutated = fmap
  (\e -> if entryIndex e == Index 12
    then e { entryIssuer = LeaderIssuer (LeaderId node1)
           , entryTerm = Term 5
           }
    else e
  )
  entries


electLeaderAndWait eventChans _ = do
    leaderElection' node0
    Right idx2 <- syncClientWrite node0 (Set "x" 7)
    leaderElection' node0

test_AEFollowerBehind =
  testDejafusWithSettings settings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    --, ("Success", alwaysTrue (== ()))
    ] $  test
  where
    settings = defaultSettings
      { _way = randomly (mkStdGen 42) 100
      }
    test :: ConcIO ()
    test = do
       let startingNodeStates =  initTestNodeStates [(node0, Term 4, entries), (node1, Term 1, Seq.take 2 entries)]

       (res, endingNodeStates) <- raftTestHarness startingNodeStates  electLeaderAndWait
       print 1
       -- TODO check logs differ from starting state
       --assertTestNodeStatesAllEqual endingNodeStates

test_AEFollowerSameIndexDifferentTerm =
  testDejafusWithSettings settings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    --, ("Success", alwaysTrue (== ()))
    ] $  test
  where
    settings = defaultSettings
      { _way = randomly (mkStdGen 42) 100
      }
    test :: ConcIO ()
    test = do
       let startingNodeStates =  initTestNodeStates [(node0, Term 4, entries), (node1, Term 5, entriesMutated)]

       (res, endingNodeStates) <- raftTestHarness startingNodeStates  electLeaderAndWait
       print 1
       -- TODO check logs differ from starting state
       --assertTestNodeStatesAllEqual endingNodeStates



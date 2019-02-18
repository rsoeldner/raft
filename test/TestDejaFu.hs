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
  (STM, TChan, newTChan, readMVar, readTChan, writeTChan, atomically, killThread, ThreadId)

import Data.Sequence (Seq(..), (><), dropWhileR, (!?))
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Serialize as S
import Numeric.Natural

import Control.Monad.Fail
import Control.Monad.Catch
import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM.TChan

import Test.DejaFu hiding (get, ThreadId)
import Test.DejaFu.Internal (Settings(..))
import Test.DejaFu.Conc hiding (ThreadId)
import Test.Tasty
import Test.Tasty.DejaFu hiding (get)

import System.Random (mkStdGen, newStdGen)

import TestUtils
import RaftTestT

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad

import Data.Time.Clock.System (getSystemTime)
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
  => (TestEventChans -> TestClientRespChans -> ConcIO a)
  -> a
  -> TestTree
testConcurrentProps test expected =
  testDejafusWithSettings settings
    [ ("No deadlocks", deadlocksNever)
    , ("No Exceptions", exceptionsNever)
    , ("Success", alwaysTrue (== Right expected))
    ] $ concurrentRaftTest test
  where
    settings = defaultSettings
      { _way = randomly (mkStdGen 42) 100
      }

    concurrentRaftTest :: (TestEventChans -> TestClientRespChans -> ConcIO a) -> ConcIO a
    concurrentRaftTest runTest =
        Control.Monad.Catch.bracket setup teardown $
          uncurry runTest . snd
      where
        setup = do
          (eventChans, clientRespChans) <- initTestChanMaps
          let (testNodeEnvs, testNodeStates) = initRaftTestEnvs eventChans clientRespChans
          tids <- forkTestNodes testNodeEnvs testNodeStates
          pure (tids, (eventChans, clientRespChans))

        teardown = mapM_ killThread . fst

leaderElection :: NodeId -> TestEventChans -> TestClientRespChans -> ConcIO Store
leaderElection nid eventChans clientRespChans =
    runRaftTestClientM client0 client0RespChan eventChans $
      leaderElection' nid eventChans
  where
     Just client0RespChan = Map.lookup client0 clientRespChans

leaderElection' :: NodeId -> TestEventChans -> RaftTestClientM Store
leaderElection' nid eventChans = do
    sysTime <- liftIO getSystemTime
    lift $ lift $ atomically $ writeTChan nodeEventChan (TimeoutEvent sysTime ElectionTimeout)
    pollForReadResponse nid
  where
    Just nodeEventChan = Map.lookup nid eventChans

incrValue :: TestEventChans -> TestClientRespChans -> ConcIO (Store, Index)
incrValue eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    runRaftTestClientM client0 client0RespChan eventChans $ do
      Right idx <- do
        syncClientWrite node0 (Set "x" 41)
        syncClientWrite node0 (Incr"x")
      store <- pollForReadResponse node0
      pure (store, idx)
  where
    Just client0RespChan = Map.lookup client0 clientRespChans

multIncrValue :: TestEventChans -> TestClientRespChans -> ConcIO (Store, Index)
multIncrValue eventChans clientRespChans = do
  leaderElection node0 eventChans clientRespChans
  runRaftTestClientM client0 client0RespChan eventChans $ do
    syncClientWrite node0 (Set "x" 0)
    Right idx <-
      fmap (Maybe.fromJust . lastMay) $
        replicateM 10 $ syncClientWrite node0 (Incr "x")
    store <- pollForReadResponse node0
    pure (store, idx)
  where
    Just client0RespChan = Map.lookup client0 clientRespChans

leaderRedirect :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
leaderRedirect eventChans clientRespChans =
  runRaftTestClientM client0 client0RespChan eventChans $ do
    Left resp <- syncClientWrite node1 (Set "x" 42)
    pure resp
  where
    Just client0RespChan = Map.lookup client0 clientRespChans

followerRedirNoLeader :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
followerRedirNoLeader = leaderRedirect

followerRedirLeader :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
followerRedirLeader eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    leaderRedirect eventChans clientRespChans

newLeaderElection :: TestEventChans -> TestClientRespChans -> ConcIO CurrentLeader
newLeaderElection eventChans clientRespChans = do
    leaderElection node0 eventChans clientRespChans
    leaderElection node1 eventChans clientRespChans
    leaderElection node2 eventChans clientRespChans
    leaderElection node1 eventChans clientRespChans
    runRaftTestClientM client0 client0RespChan eventChans $ do
      Left ldr <- syncClientRead node0
      pure ldr
  where
    Just client0RespChan = Map.lookup client0 clientRespChans

comprehensive :: TestEventChans -> TestClientRespChans -> ConcIO (Index, Store, CurrentLeader)
comprehensive eventChans clientRespChans =
  runRaftTestClientM client0 client0RespChan eventChans $ do
    leaderElection'' node0
    Right idx2 <- syncClientWrite node0 (Set "x" 7)
    Right idx3 <- syncClientWrite node0 (Set "y" 3)
    Left (CurrentLeader _) <- syncClientWrite node1 (Incr "y")
    Right _ <- syncClientRead node0

    leaderElection'' node1
    Right idx5 <- syncClientWrite node1 (Incr "x")
    Right idx6 <- syncClientWrite node1 (Incr "y")
    Right idx7 <- syncClientWrite node1 (Set "z" 40)
    Left (CurrentLeader _) <- syncClientWrite node2 (Incr "y")
    Right _ <- syncClientRead node1

    leaderElection'' node2
    Right idx9 <- syncClientWrite node2 (Incr "z")
    Right idx10 <- syncClientWrite node2 (Incr "x")
    Left _ <- syncClientWrite node1 (Set "q" 100)
    Right idx11 <- syncClientWrite node2 (Incr "y")
    Left _ <- syncClientWrite node0 (Incr "z")
    Right idx12 <- syncClientWrite node2 (Incr "y")
    Left (CurrentLeader _) <- syncClientWrite node0 (Incr "y")
    Right _ <- syncClientRead node2

    leaderElection'' node0
    Right idx14 <- syncClientWrite node0 (Incr "z")
    Left (CurrentLeader _) <- syncClientWrite node1 (Incr "y")

    Right store <- syncClientRead node0
    Left ldr <- syncClientRead node1

    pure (idx14, store, ldr)
  where
    leaderElection'' nid = leaderElection' nid eventChans
    Just client0RespChan = Map.lookup client0 clientRespChans

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | This function can be safely "run" without worry about impacting the client
-- SerialNum of the client requests.
--
-- Warning: If read requests start to include serial numbers, this function will
-- no longer be safe to `runRaftTestClientM` on.
pollForReadResponse :: NodeId -> RaftTestClientM Store
pollForReadResponse nid = do
  eRes <- clientReadFrom nid ClientReadStateMachine
  case eRes of
    -- TODO Handle other cases of 'ClientReadResp'
    Right (ClientReadRespStateMachine res) -> pure res
    _ -> do
      liftIO $ Control.Monad.Conc.Class.threadDelay 10000
      pollForReadResponse nid

syncClientRead :: NodeId -> RaftTestClientM (Either CurrentLeader Store)
syncClientRead nid = do
  eRes <- clientReadFrom nid ClientReadStateMachine
  case eRes of
    -- TODO Handle other cases of 'ClientReadResp'
    Right (ClientReadRespStateMachine store) -> pure $ Right store
    Left (RaftClientUnexpectedRedirect (ClientRedirResp ldr)) -> pure $ Left ldr
    _ -> panic "Failed to recieve valid read response"

syncClientWrite
  :: NodeId
  -> StoreCmd
  -> RaftTestClientM (Either CurrentLeader Index)
syncClientWrite nid cmd = do
  eRes <- clientWriteTo nid cmd
  case eRes of
    Right (ClientWriteResp idx sn) -> do
      Just nodeEventChan <- lift (asks (Map.lookup nid . testClientEnvNodeEventChans))
      pure $ Right idx
    Left (RaftClientUnexpectedRedirect (ClientRedirResp ldr)) -> pure $ Left ldr
    _ -> panic "Failed to receive client write response..."

heartbeat :: TestEventChan -> ConcIO ()
heartbeat eventChan = do
  sysTime <- liftIO getSystemTime
  atomically $ writeTChan eventChan (TimeoutEvent sysTime HeartbeatTimeout)

clientReadReq :: ClientId -> Event StoreCmd
clientReadReq cid = MessageEvent $ ClientRequestEvent $ ClientRequest cid (ClientReadReq ClientReadStateMachine)

clientReadRespChan :: RaftTestClientM (ClientResponse Store StoreCmd)
clientReadRespChan = do
  clientRespChan <- lift (asks testClientEnvRespChan)
  lift $ lift $ atomically $ readTChan clientRespChan

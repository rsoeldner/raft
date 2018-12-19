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

import Raft
import Raft.Client

--------------------------------------------------------------------------------
-- Test State Machine & Commands
--------------------------------------------------------------------------------

type Var = ByteString

data StoreCmd
  = Set Var Natural
  | Incr Var
  deriving (Show, Generic)

instance S.Serialize StoreCmd

type Store = Map Var Natural

data StoreCtx = StoreCtx

instance RSMP Store StoreCmd where
  data RSMPError Store StoreCmd = StoreError Text deriving (Show)
  type RSMPCtx Store StoreCmd = StoreCtx
  applyCmdRSMP _ store cmd =
    Right $ case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

instance RSM Store StoreCmd RaftTestM where
  validateCmd _ = pure (Right ())
  askRSMPCtx = pure StoreCtx

type TestEventChan = EventChan ConcIO StoreCmd
type TestEventChans = Map NodeId TestEventChan

type TestClientRespChan = TChan (STM ConcIO) (ClientResponse Store)
type TestClientRespChans = Map ClientId TestClientRespChan

-- | Node specific environment
data TestNodeEnv = TestNodeEnv
  { testNodeEventChans :: TestEventChans
  , testClientRespChans :: TestClientRespChans
  , testNodeConfig :: NodeConfig
  }

-- | Node specific state
data TestNodeState = TestNodeState
  { testNodeLog :: Entries StoreCmd
  , testNodePersistentState :: PersistentState
  }

-- | A map of node ids to their respective node data
type TestNodeStates = Map NodeId TestNodeState

newtype RaftTestM a = RaftTestM {
    unRaftTestM :: ReaderT TestNodeEnv (StateT TestNodeStates ConcIO) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadReader TestNodeEnv, MonadState TestNodeStates, MonadFail)

deriving instance MonadThrow RaftTestM
deriving instance MonadCatch RaftTestM
deriving instance MonadMask RaftTestM
deriving instance MonadConc RaftTestM

runRaftTestM :: TestNodeEnv -> TestNodeStates -> RaftTestM a -> ConcIO a
runRaftTestM testEnv testState =
  flip evalStateT testState . flip runReaderT testEnv . unRaftTestM

newtype RaftTestError = RaftTestError Text
  deriving (Show)

instance Exception RaftTestError
throwTestErr = throw . RaftTestError

askSelfNodeId :: RaftTestM NodeId
askSelfNodeId = asks (configNodeId . testNodeConfig)

lookupNodeEventChan :: NodeId -> RaftTestM TestEventChan
lookupNodeEventChan nid = do
  testChanMap <- asks testNodeEventChans
  case Map.lookup nid testChanMap of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestEnv"
    Just testChan -> pure testChan

getNodeState :: NodeId -> RaftTestM TestNodeState
getNodeState nid = do
  testState <- get
  case Map.lookup nid testState of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestNodeStates"
    Just testNodeState -> pure testNodeState

modifyNodeState :: NodeId -> (TestNodeState -> TestNodeState) -> RaftTestM ()
modifyNodeState nid f =
  modify $ \testState ->
    case Map.lookup nid testState of
      Nothing -> panic $ "Node id " <> show nid <> " does not exist in TestNodeStates"
      Just testNodeState -> Map.insert nid (f testNodeState) testState

instance RaftPersist RaftTestM where
  type RaftPersistError RaftTestM = RaftTestError
  writePersistentState pstate' = do
    nid <- askSelfNodeId
    fmap Right $ modify $ \testState ->
      case Map.lookup nid testState of
        Nothing -> testState
        Just testNodeState -> do
          let newTestNodeState = testNodeState { testNodePersistentState = pstate' }
          Map.insert nid newTestNodeState testState
  readPersistentState = do
    nid <- askSelfNodeId
    testState <- get
    case Map.lookup nid testState of
      Nothing -> pure $ Left (RaftTestError "Failed to find node in environment")
      Just testNodeState -> pure $ Right (testNodePersistentState testNodeState)

instance RaftSendRPC RaftTestM StoreCmd where
  sendRPC nid rpc = do
    eventChan <- lookupNodeEventChan nid
    atomically $ writeTChan eventChan (MessageEvent (RPCMessageEvent rpc))

instance RaftSendClient RaftTestM Store where
  sendClient cid cr = do
    clientRespChans <- asks testClientRespChans
    case Map.lookup cid clientRespChans of
      Nothing -> panic "Failed to find client id in environment"
      Just clientRespChan -> atomically (writeTChan clientRespChan cr)

instance RaftWriteLog RaftTestM StoreCmd where
  type RaftWriteLogError RaftTestM = RaftTestError
  writeLogEntries entries = do
    nid <- askSelfNodeId
    fmap Right $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
         in testNodeState { testNodeLog = log >< entries }

instance RaftDeleteLog RaftTestM StoreCmd where
  type RaftDeleteLogError RaftTestM = RaftTestError
  deleteLogEntriesFrom idx = do
    nid <- askSelfNodeId
    fmap (const $ Right DeleteSuccess) $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
            newLog = dropWhileR ((<=) idx . entryIndex) log
         in testNodeState { testNodeLog = newLog }

instance RaftReadLog RaftTestM StoreCmd where
  type RaftReadLogError RaftTestM = RaftTestError
  readLogEntry (Index idx)
    | idx <= 0 = pure $ Right Nothing
    | otherwise = do
        log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
        case log !? fromIntegral (pred idx) of
          Nothing -> pure (Right Nothing)
          Just e
            | entryIndex e == Index idx -> pure (Right $ Just e)
            | otherwise -> pure $ Left (RaftTestError "Malformed log")
  readLastLogEntry = do
    log <- fmap testNodeLog . getNodeState =<< askSelfNodeId
    case log of
      Empty -> pure (Right Nothing)
      _ :|> lastEntry -> pure (Right (Just lastEntry))

--------------------------------------------------------------------------------

data TestClientEnv = TestClientEnv
  { testClientEnvRespChan :: TestClientRespChan
  , testClientEnvNodeEventChans :: TestEventChans
  }

type RaftTestClientM' = ReaderT TestClientEnv ConcIO
type RaftTestClientM = RaftClientT Store StoreCmd RaftTestClientM'

instance RaftClientSend RaftTestClientM' StoreCmd where
  type RaftClientSendError RaftTestClientM' StoreCmd = ()
  raftClientSend nid creq = do
    Just nodeEventChan <- asks (Map.lookup nid . testClientEnvNodeEventChans)
    lift $ atomically $ writeTChan nodeEventChan (MessageEvent (ClientRequestEvent creq))
    pure (Right ())

instance RaftClientRecv RaftTestClientM' Store where
  type RaftClientRecvError RaftTestClientM' Store = ()
  raftClientRecv = do
    clientRespChan <- asks testClientEnvRespChan
    fmap Right $ lift $ atomically $ readTChan clientRespChan

runRaftTestClientM
  :: ClientId
  -> TestClientRespChan
  -> TestEventChans
  -> RaftTestClientM a
  -> ConcIO a
runRaftTestClientM cid chan chans rtcm = do
  raftClientState <- initRaftClientState <$> liftIO newStdGen
  let raftClientEnv = RaftClientEnv cid
      testClientEnv = TestClientEnv chan chans
   in flip runReaderT testClientEnv
    . runRaftClientT raftClientEnv raftClientState { raftClientRaftNodes = Map.keysSet chans }
    $ rtcm

--------------------------------------------------------------------------------

initTestChanMaps :: ConcIO (Map NodeId TestEventChan, Map ClientId TestClientRespChan)
initTestChanMaps = do
  eventChans <-
    Map.fromList . zip (toList nodeIds) <$>
      atomically (replicateM (length nodeIds) newTChan)
  clientRespChans <-
    Map.fromList . zip [client0] <$>
      atomically (replicateM 1 newTChan)
  pure (eventChans, clientRespChans)

initRaftTestEnvs
  :: Map NodeId TestEventChan
  -> Map ClientId TestClientRespChan
  -> ([TestNodeEnv], TestNodeStates)
initRaftTestEnvs eventChans clientRespChans = (testNodeEnvs, testStates)
  where
    testNodeEnvs = map (TestNodeEnv eventChans clientRespChans) testConfigs
    testStates = Map.fromList $ zip (toList nodeIds) $
      replicate (length nodeIds) (TestNodeState mempty initPersistentState)

runTestNode :: TestNodeEnv -> TestNodeStates -> ConcIO ()
runTestNode testEnv testState = do
    runRaftTestM testEnv testState $
      runRaftT initRaftNodeState raftEnv $
        handleEventLoop (mempty :: Store)
  where
    nid = configNodeId (testNodeConfig testEnv)
    Just eventChan = Map.lookup nid (testNodeEventChans testEnv)
    raftEnv = RaftEnv eventChan dummyTimer dummyTimer (testNodeConfig testEnv) NoLogs
    dummyTimer = pure ()

forkTestNodes :: [TestNodeEnv] -> TestNodeStates -> ConcIO [ThreadId ConcIO]
forkTestNodes testEnvs testStates =
  mapM (fork . flip runTestNode testStates) testEnvs

--------------------------------------------------------------------------------

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
    lift $ lift $ atomically $ writeTChan nodeEventChan (TimeoutEvent ElectionTimeout)
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
-- Warning: If read requests start to include serial numbers, this function will
-- no longer be safe to `runRaftTestClientM` on.
pollForReadResponse :: NodeId -> RaftTestClientM Store
pollForReadResponse nid = do
  eRes <- clientReadFrom nid
  case eRes of
    Right (ClientReadResp res) -> pure res
    _ -> do
      liftIO $ Control.Monad.Conc.Class.threadDelay 10000
      pollForReadResponse nid

syncClientRead :: NodeId -> RaftTestClientM (Either CurrentLeader Store)
syncClientRead nid = do
  eRes <- clientReadFrom nid
  case eRes of
    Right (ClientReadResp store) -> pure $ Right store
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
heartbeat eventChan = atomically $ writeTChan eventChan (TimeoutEvent HeartbeatTimeout)

clientReadReq :: ClientId -> Event StoreCmd
clientReadReq cid = MessageEvent $ ClientRequestEvent $ ClientRequest cid ClientReadReq

clientReadRespChan :: RaftTestClientM (ClientResponse Store)
clientReadRespChan = do
  clientRespChan <- lift (asks testClientEnvRespChan)
  lift $ lift $ atomically $ readTChan clientRespChan

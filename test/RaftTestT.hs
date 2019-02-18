{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}


module RaftTestT where

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

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad

import System.Random (mkStdGen, newStdGen)

import TestUtils

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

instance RaftStateMachinePure Store StoreCmd where
  data RaftStateMachinePureError Store StoreCmd = StoreError Text deriving (Show)
  type RaftStateMachinePureCtx Store StoreCmd = StoreCtx
  rsmTransition _ store cmd =
    Right $ case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

instance Monad m => RaftStateMachine (RaftTestT m) Store StoreCmd where
  validateCmd _ = pure (Right ())
  askRaftStateMachinePureCtx = pure StoreCtx

type TestEventChan m = RaftEventChan StoreCmd (RaftTestT m)
type TestEventChans m = Map NodeId (TestEventChan m)

type TestClientRespChan m = TChan (STM m) (ClientResponse Store StoreCmd)
type TestClientRespChans m = Map ClientId (TestClientRespChan m)

-- | Node specific environment
data TestNodeEnv m = TestNodeEnv
  { testNodeEventChans :: TestEventChans m
  , testClientRespChans :: TestClientRespChans m
  , testRaftNodeConfig :: RaftNodeConfig
  }

-- | Node specific state
data TestNodeState = TestNodeState
  { testNodeLog :: Entries StoreCmd
  , testNodePersistentState :: PersistentState
  }

-- | A map of node ids to their respective node data
type TestNodeStates = Map NodeId TestNodeState

newtype RaftTestT m a = RaftTestT {
    unRaftTestT :: ReaderT (TestNodeEnv m) (StateT TestNodeStates m) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadReader (TestNodeEnv m), MonadState TestNodeStates, MonadFail)

type RaftTestM = RaftTestT ConcIO

deriving newtype instance MonadThrow m => MonadThrow (RaftTestT m)
deriving newtype instance MonadCatch m => MonadCatch (RaftTestT m)
deriving newtype instance MonadMask m => MonadMask (RaftTestT m)
deriving newtype instance MonadConc m => MonadConc (RaftTestT m)

runRaftTestT :: Monad m => TestNodeEnv m -> TestNodeStates -> RaftTestT m a -> m a
runRaftTestT testEnv testState =
  flip evalStateT testState . flip runReaderT testEnv . unRaftTestT

newtype RaftTestError = RaftTestError Text
  deriving (Show)

instance Exception RaftTestError

throwTestErr :: MonadConc m => Text -> m a
throwTestErr = throw . RaftTestError

askSelfNodeId :: Monad m => RaftTestT m NodeId
askSelfNodeId = asks (configNodeId . testRaftNodeConfig)

lookupNodeEventChan :: MonadConc m => NodeId -> (RaftTestT m) (TestEventChan m)
lookupNodeEventChan nid = do
  testChanMap <- asks testNodeEventChans
  case Map.lookup nid testChanMap of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestEnv"
    Just testChan -> pure testChan

getNodeState :: MonadConc m => NodeId -> (RaftTestT m) TestNodeState
getNodeState nid = do
  testState <- get
  case Map.lookup nid testState of
    Nothing -> throwTestErr $ "Node id " <> show nid <> " does not exist in TestNodeStates"
    Just testNodeState -> pure testNodeState

modifyNodeState :: Monad m =>  NodeId -> (TestNodeState -> TestNodeState) -> (RaftTestT m) ()
modifyNodeState nid f =
  modify $ \testState ->
    case Map.lookup nid testState of
      Nothing -> panic $ "Node id " <> show nid <> " does not exist in TestNodeStates"
      Just testNodeState -> Map.insert nid (f testNodeState) testState

instance Monad m => RaftPersist (RaftTestT m) where
  type RaftPersistError (RaftTestT m) = RaftTestError
  initializePersistentState = pure (Right ())
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

instance MonadConc m => RaftSendRPC (RaftTestT m) StoreCmd where
  sendRPC nid rpc = do
    eventChan <- lookupNodeEventChan nid
    atomically $ writeTChan eventChan (MessageEvent (RPCMessageEvent rpc))

instance RaftSendClient (RaftTestT m) Store StoreCmd where
  sendClient cid cr = do
    clientRespChans <- asks testClientRespChans
    case Map.lookup cid clientRespChans of
      Nothing -> panic "Failed to find client id in environment"
      Just clientRespChan -> atomically (writeTChan clientRespChan cr)

instance RaftInitLog (RaftTestT m) StoreCmd where
  type RaftInitLogError (RaftTestT m) = RaftTestError
  -- No log initialization needs to be done here, everything is in memory.
  initializeLog _ = pure (Right ())

instance RaftWriteLog (RaftTestT m) StoreCmd where
  type RaftWriteLogError (RaftTestT m) = RaftTestError
  writeLogEntries entries = do
    nid <- askSelfNodeId
    fmap Right $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
         in testNodeState { testNodeLog = log >< entries }

instance RaftDeleteLog (RaftTestT m) StoreCmd where
  type RaftDeleteLogError (RaftTestT m) = RaftTestError
  deleteLogEntriesFrom idx = do
    nid <- askSelfNodeId
    fmap (const $ Right DeleteSuccess) $
      modifyNodeState nid $ \testNodeState ->
        let log = testNodeLog testNodeState
            newLog = dropWhileR ((<=) idx . entryIndex) log
         in testNodeState { testNodeLog = newLog }

instance RaftReadLog (RaftTestT m) StoreCmd where
  type RaftReadLogError (RaftTestT m) = RaftTestError
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

instance MonadRaftChan StoreCmd (RaftTestT m) where
  type RaftEventChan StoreCmd (RaftTestT m) = TChan (STM ConcIO) (Event StoreCmd)
  readRaftChan = RaftTestT . lift . lift . readRaftChan
  writeRaftChan chan = RaftTestT . lift . lift . writeRaftChan chan
  newRaftChan = RaftTestT . lift . lift $ newRaftChan

instance MonadRaftFork (RaftTestT m) where
  type RaftThreadId (RaftTestT m) = RaftThreadId ConcIO
  raftFork r m = do
    testNodeEnv <- ask
    testNodeStates <- get
    RaftTestT . lift . lift $ raftFork r (runRaftTestT testNodeEnv testNodeStates m)

--------------------------------------------------------------------------------

data TestClientEnv m = TestClientEnv
  { testClientEnvRespChan :: TestClientRespChan m
  , testClientEnvNodeEventChans :: TestEventChans m
  }

type RaftTestClientT' m = ReaderT (TestClientEnv m) m
type RaftTestClientT m = RaftClientT Store StoreCmd (RaftTestClientT' m)

instance RaftClientSend (RaftTestClientT' m) StoreCmd where
  type RaftClientSendError (RaftTestClientT' m) StoreCmd = ()
  raftClientSend nid creq = do
    Just nodeEventChan <- asks (Map.lookup nid . testClientEnvNodeEventChans)
    lift $ atomically $ writeTChan nodeEventChan (MessageEvent (ClientRequestEvent creq))
    pure (Right ())

instance RaftClientRecv (RaftTestClientT' m) Store StoreCmd where
  type RaftClientRecvError (RaftTestClientT' m) Store = ()
  raftClientRecv = do
    clientRespChan <- asks testClientEnvRespChan
    fmap Right $ lift $ atomically $ readTChan clientRespChan

runRaftTestClientT
  :: ClientId
  -> (TestClientRespChan m)
  -> TestEventChans m
  -> RaftTestClientT m a
  -> m a
runRaftTestClientT cid chan chans rtcm = do
  raftClientState <- initRaftClientState mempty <$> liftIO newStdGen
  let raftClientEnv = RaftClientEnv cid
      testClientEnv = TestClientEnv chan chans
   in flip runReaderT testClientEnv
    . runRaftClientT raftClientEnv raftClientState { raftClientRaftNodes = Map.keysSet chans }
    $ rtcm

--------------------------------------------------------------------------------

initTestChanMaps :: MonadConc m => m (Map NodeId (TestEventChan m), Map ClientId (TestClientRespChan m))
initTestChanMaps = do
  eventChans <-
    Map.fromList . zip (toList nodeIds) <$>
      atomically (replicateM (length nodeIds) newTChan)
  clientRespChans <-
    Map.fromList . zip [client0] <$>
      atomically (replicateM 1 newTChan)
  pure (eventChans, clientRespChans)

initRaftTestEnvs
  :: Map NodeId (TestEventChan m)
  -> Map ClientId (TestClientRespChan m)
  -> ([(TestNodeEnv m)], TestNodeStates)
initRaftTestEnvs eventChans clientRespChans = (testNodeEnvs, testStates)
  where
    testNodeEnvs = map (TestNodeEnv eventChans clientRespChans) testConfigs
    testStates = Map.fromList $ zip (toList nodeIds) $
      replicate (length nodeIds) (TestNodeState mempty initPersistentState)

runTestNode :: (TestNodeEnv m) -> TestNodeStates -> ConcIO ()
runTestNode testEnv testState = do
    runRaftTestT testEnv testState $
      runRaftT initRaftNodeState raftEnv $
        handleEventLoop (mempty :: Store)
  where
    nid = configNodeId (testRaftNodeConfig testEnv)
    Just eventChan = Map.lookup nid (testNodeEventChans testEnv)
    raftEnv = RaftEnv eventChan dummyTimer dummyTimer (testRaftNodeConfig testEnv) NoLogs
    dummyTimer = pure ()

forkTestNodes :: [(TestNodeEnv m)] -> TestNodeStates -> ConcIO [ThreadId ConcIO]
forkTestNodes testEnvs testStates =
  mapM (fork . flip runTestNode testStates) testEnvs

--------------------------------------------------------------------------------



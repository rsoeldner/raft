{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}

module Raft.Client where

import Protolude

import Control.Monad.Fail
import Control.Monad.Trans.Class

import qualified Data.Set as Set
import qualified Data.Serialize as S
import Numeric.Natural (Natural)

import System.Random
import System.Console.Haskeline.MonadException (MonadException(..), RunIO(..))

import Raft.Types

--------------------------------------------------------------------------------
-- Raft Interface
--------------------------------------------------------------------------------

{- This is the interface with which Raft nodes interact with client programs -}

-- | Interface for Raft nodes to send messages to clients
class RaftSendClient m sm where
  sendClient :: ClientId -> ClientResponse sm -> m ()

-- | Interface for Raft nodes to receive messages from clients
class Show (RaftRecvClientError m v) => RaftRecvClient m v where
  type RaftRecvClientError m v
  receiveClient :: m (Either (RaftRecvClientError m v) (ClientRequest v))

newtype SerialNum = SerialNum Natural
  deriving (Show, Read, Eq, Ord, Enum, Num, Generic, S.Serialize)

-- | Representation of a client request coupled with the client id
data ClientRequest v
  = ClientRequest ClientId (ClientReq v)
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientRequest v)

-- | Representation of a client request
data ClientReq v
  = ClientReadReq -- ^ Request the latest state of the state machine
  | ClientWriteReq SerialNum v -- ^ Write a command
  deriving (Show, Generic)

instance S.Serialize v => S.Serialize (ClientReq v)

-- | Representation of a client response
data ClientResponse s
  = ClientReadResponse (ClientReadResp s)
    -- ^ Respond with the latest state of the state machine.
  | ClientWriteResponse ClientWriteResp
    -- ^ Respond with the index of the entry appended to the log
  | ClientRedirectResponse ClientRedirResp
    -- ^ Respond with the node id of the current leader
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientResponse s)

-- | Representation of a read response to a client
-- The `s` stands for the "current" state of the state machine
newtype ClientReadResp s
  = ClientReadResp s
  deriving (Show, Generic)

instance S.Serialize s => S.Serialize (ClientReadResp s)

-- | Representation of a write response to a client
data ClientWriteResp
  = ClientWriteResp Index SerialNum
  -- ^ Index of the entry appended to the log due to the previous client request
  deriving (Show, Generic)

instance S.Serialize ClientWriteResp

-- | Representation of a redirect response to a client
data ClientRedirResp
  = ClientRedirResp CurrentLeader
  deriving (Show, Generic)

instance S.Serialize ClientRedirResp

--------------------------------------------------------------------------------
-- Client Interface
--------------------------------------------------------------------------------

{- This is the interface with which clients interact with Raft nodes -}

class Monad m => RaftClientSend m v where
  type RaftClientSendError m v
  raftClientSend :: NodeId -> ClientRequest v -> m (Either (RaftClientSendError m v) ())

class Monad m => RaftClientRecv m s where
  type RaftClientRecvError m s
  raftClientRecv :: m (Either (RaftClientRecvError m s) (ClientResponse s))

data RaftClientState = RaftClientState
  { raftClientCurrentLeader :: CurrentLeader
  , raftClientSerialNum :: SerialNum
  , raftClientRaftNodes :: Set NodeId
  , raftClientRandomGen :: StdGen
  }

data RaftClientEnv = RaftClientEnv
  { raftClientId :: ClientId
  }

initRaftClientState :: StdGen -> RaftClientState
initRaftClientState = RaftClientState NoLeader 0 mempty

newtype RaftClientT v m a = RaftClientT
  { unRaftClientT :: ReaderT RaftClientEnv (StateT RaftClientState m) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadState RaftClientState, MonadReader RaftClientEnv, MonadFail, Alternative, MonadPlus)

instance MonadTrans (RaftClientT v) where
  lift = RaftClientT . lift . lift

instance RaftClientSend m v => RaftClientSend (RaftClientT v m) v where
  type RaftClientSendError (RaftClientT v m) v = RaftClientSendError m v
  raftClientSend nid creq = lift (raftClientSend nid creq)

instance RaftClientRecv m s => RaftClientRecv (RaftClientT v m) s where
  type RaftClientRecvError (RaftClientT v m) s = RaftClientRecvError m s
  raftClientRecv = lift raftClientRecv

-- This annoying instance is because of the Haskeline library, letting us use a
-- custom monad transformer stack as the base monad of 'InputT'. IMO it should
-- be automatically derivable. Why does haskeline use a custom exception
-- monad... ?
instance MonadException m => MonadException (RaftClientT v m) where
  controlIO f =
    RaftClientT $ ReaderT $ \r -> StateT $ \s ->
      controlIO $ \(RunIO run) ->
        let run' = RunIO (fmap (RaftClientT . ReaderT . const . StateT . const) . run . flip runStateT s . flip runReaderT r . unRaftClientT)
         in fmap (flip runStateT s . flip runReaderT r . unRaftClientT) $ f run'

runRaftClientT :: Monad m => RaftClientEnv -> RaftClientState -> RaftClientT v m a -> m a
runRaftClientT raftClientEnv raftClientState =
  flip evalStateT raftClientState . flip runReaderT raftClientEnv . unRaftClientT

--------------------------------------------------------------------------------

data RaftClientError s v m where
  RaftClientSendError :: RaftClientSendError m v -> RaftClientError s v m
  RaftClientRecvError :: RaftClientRecvError m s -> RaftClientError s v m

deriving instance (Show (RaftClientSendError m v), Show (RaftClientRecvError m s)) => Show (RaftClientError s v m)

-- | Send a read request to the curent leader and wait for a response
clientRead
  :: (RaftClientSend m v, RaftClientRecv m s)
  => RaftClientT v m (Either (RaftClientError s v m) (ClientResponse s))
clientRead = do
  eSend <- clientSendRead
  case eSend of
    Left err -> pure (Left (RaftClientSendError err))
    Right _ -> first RaftClientRecvError <$> clientRecv

-- | Send a read request to a specific raft node, regardless of leader, and wait
-- for a response.
clientRead_
  :: (RaftClientSend m v, RaftClientRecv m s)
  => NodeId
  -> RaftClientT v m (Either (RaftClientError s v m) (ClientResponse s))
clientRead_ nid = do
  eSend <- clientSendReadTo nid
  case eSend of
    Left err -> pure (Left (RaftClientSendError err))
    Right _ -> first RaftClientRecvError <$> clientRecv

-- | Send a write request to the current leader and wait for a response
clientWrite
  :: (RaftClientSend m v, RaftClientRecv m s)
  => v
  -> RaftClientT v m (Either (RaftClientError s v m) (ClientResponse s))
clientWrite cmd = do
  eSend <- clientSendWrite cmd
  case eSend of
    Left err -> pure (Left (RaftClientSendError err))
    Right _ -> first RaftClientRecvError <$> clientRecv

-- | Send a read request to a specific raft node, regardless of leader, and wait
-- for a response.
clientWrite_
  :: (RaftClientSend m v, RaftClientRecv m s)
  => NodeId
  -> v
  -> RaftClientT v m (Either (RaftClientError s v m) (ClientResponse s))
clientWrite_ nid cmd = do
  eSend <- clientSendWriteTo nid cmd
  case eSend of
    Left err -> pure (Left (RaftClientSendError err))
    Right _ -> first RaftClientRecvError <$> clientRecv

--------------------------------------------------------------------------------

-- | Send a read request to the current leader. Nonblocking.
clientSendRead
  :: RaftClientSend m v
  => RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendRead =
  asks raftClientId >>= \cid ->
    clientSend (ClientRequest cid ClientReadReq)

clientSendReadTo
  :: RaftClientSend m v
  => NodeId
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendReadTo nid =
  asks raftClientId >>= \cid ->
    clientSendTo nid (ClientRequest cid ClientReadReq)

-- | Send a write request to the current leader. Nonblocking.
clientSendWrite
  :: RaftClientSend m v
  => v
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendWrite v = do
  asks raftClientId >>= \cid -> gets raftClientSerialNum >>= \sn ->
    clientSend (ClientRequest cid (ClientWriteReq sn v))

-- | Send a write request to a specific raft node, ignoring the current
-- leader. This function is used in testing.
clientSendWriteTo
  :: RaftClientSend m v
  => NodeId
  -> v
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendWriteTo nid v =
  asks raftClientId >>= \cid -> gets raftClientSerialNum >>= \sn ->
    clientSendTo nid (ClientRequest cid (ClientWriteReq sn v))

-- | Send a request to the current leader. Nonblocking.
clientSend
  :: RaftClientSend m v
  => ClientRequest v
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSend creq = do
  currLeader <- gets raftClientCurrentLeader
  case currLeader of
    NoLeader -> clientSendRandom creq
    CurrentLeader (LeaderId nid) ->
      raftClientSend nid creq

-- | Send a request to a specific raft node, ignoring the current leader.
-- This function is used in testing.
clientSendTo
  :: RaftClientSend m v
  => NodeId
  -> ClientRequest v
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendTo nid creq = raftClientSend nid creq

-- | Send a request to a random node; This function is used if there is no
-- leader.
clientSendRandom
  :: RaftClientSend m v
  => ClientRequest v
  -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendRandom creq = do
  raftNodes <- gets raftClientRaftNodes
  randomGen <- gets raftClientRandomGen
  let (idx, newRandomGen) = randomR (0, length raftNodes - 1) randomGen
  case atMay (toList raftNodes) idx of
    Nothing -> panic "No raft nodes known by client"
    Just nid -> do
      modify $ \s -> s { raftClientRandomGen = newRandomGen }
      raftClientSend nid creq

-- | Wait for a response from the current leader.
-- This function handles leader changes and write request serial numbers.
clientRecv
  :: RaftClientRecv m s
  => RaftClientT v m (Either (RaftClientRecvError m s) (ClientResponse s))
clientRecv = do
  ecresp <- raftClientRecv
  case ecresp of
    Left err -> pure (Left err)
    Right cresp ->
      case cresp of
        ClientWriteResponse (ClientWriteResp _ (SerialNum n)) -> do
          SerialNum m <- gets raftClientSerialNum
          if m == n
            then do
              modify $ \s -> s
                { raftClientSerialNum = SerialNum (succ m) }
              pure (Right cresp)
            else panic "Received invalid serial number response"
        ClientRedirectResponse (ClientRedirResp currLdr) -> do
          modify $ \s -> s
            { raftClientCurrentLeader = currLdr }
          pure (Right cresp)
        _ -> pure (Right cresp)

--------------------------------------------------------------------------------

clientAddNode :: Monad m => NodeId -> RaftClientT v m ()
clientAddNode nid = modify $ \s ->
  s { raftClientRaftNodes = Set.insert nid (raftClientRaftNodes s) }

clientGetNodes :: Monad m => RaftClientT v m (Set NodeId)
clientGetNodes = gets raftClientRaftNodes

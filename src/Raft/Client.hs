{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Raft.Client where

import Protolude

import Control.Monad.Fail
import Control.Monad.Trans.Class

import qualified Data.Serialize as S
import Numeric.Natural (Natural)

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
  raftClientSend :: NodeId -> ClientRequest v -> m ()

class Monad m => RaftClientRecv m s where
  raftClientRecv :: m (ClientResponse s)

newtype RaftClientT v m a = RaftClientT
  { unRaftClientT :: ReaderT ClientId (StateT SerialNum m) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadState SerialNum, MonadReader ClientId, MonadFail)

instance MonadTrans (RaftClientT v) where
  lift = RaftClientT . lift . lift

runRaftClientT :: Monad m => ClientId -> SerialNum -> RaftClientT v m a -> m a
runRaftClientT cid sn = flip evalStateT sn . flip runReaderT cid . unRaftClientT

clientSendRead
  :: forall m v. RaftClientSend m v
  => NodeId -> RaftClientT v m ()
clientSendRead nid =
  ask >>= \cid -> lift $
    raftClientSend @m @v nid (ClientRequest cid ClientReadReq)

clientSendWrite
  :: RaftClientSend m v
  => NodeId -> v -> RaftClientT v m ()
clientSendWrite nid v = do
  ask >>= \cid -> get >>= \sn -> lift $
    raftClientSend nid (ClientRequest cid (ClientWriteReq sn v))

clientRecv
  :: RaftClientRecv m s
  => RaftClientT v m (ClientResponse s)
clientRecv = do
  cresp <- lift raftClientRecv
  case cresp of
    ClientWriteResponse (ClientWriteResp _ (SerialNum n)) -> do
      SerialNum m <- get
      if m == n
        then put (SerialNum (succ m))
        else panic "Received invalid serial number response"
    otherwise -> pure ()
  pure cresp

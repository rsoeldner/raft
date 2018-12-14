{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}

module Raft.Client where

import Protolude

import Control.Monad.Base
import Control.Monad.Fail
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control

import qualified Data.Serialize as S
import Numeric.Natural (Natural)

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

newtype RaftClientT v m a = RaftClientT
  { unRaftClientT :: ReaderT ClientId (StateT SerialNum m) a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadState SerialNum, MonadReader ClientId, MonadFail, Alternative, MonadPlus)

instance MonadTrans (RaftClientT v) where
  lift = RaftClientT . lift . lift

deriving instance MonadBase IO m => MonadBase IO (RaftClientT v m)

instance MonadTransControl (RaftClientT v) where
    type StT (RaftClientT v) a = StT (ReaderT ClientId) (StT (StateT SerialNum) a)
    liftWith = defaultLiftWith2 RaftClientT unRaftClientT
    restoreT = defaultRestoreT2 RaftClientT

instance (MonadBaseControl IO m) => MonadBaseControl IO (RaftClientT v m) where
    type StM (RaftClientT v m) a = ComposeSt (RaftClientT v) m a
    liftBaseWith    = defaultLiftBaseWith
    restoreM        = defaultRestoreM

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

runRaftClientT :: Monad m => ClientId -> SerialNum -> RaftClientT v m a -> m a
runRaftClientT cid sn = flip evalStateT sn . flip runReaderT cid . unRaftClientT

clientSendRead
  :: forall m v. RaftClientSend m v
  => NodeId -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendRead nid =
  ask >>= \cid -> lift $
    raftClientSend @m @v nid (ClientRequest cid ClientReadReq)

clientSendWrite
  :: RaftClientSend m v
  => NodeId -> v -> RaftClientT v m (Either (RaftClientSendError m v) ())
clientSendWrite nid v = do
  ask >>= \cid -> get >>= \sn -> lift $
    raftClientSend nid (ClientRequest cid (ClientWriteReq sn v))

clientRecv
  :: RaftClientRecv m s
  => RaftClientT v m (Either (RaftClientRecvError m s) (ClientResponse s))
clientRecv = do
  ecresp <- lift raftClientRecv
  case ecresp of
    Left err -> pure (Left err)
    Right cresp ->
      case cresp of
        ClientWriteResponse (ClientWriteResp _ (SerialNum n)) -> do
          SerialNum m <- get
          if m == n
            then do
              put (SerialNum (succ m))
              pure (Right cresp)
            else panic "Received invalid serial number response"
        _ -> pure (Right cresp)

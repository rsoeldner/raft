{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Examples.Raft.Socket.Client where

import Protolude

import           Control.Monad.Base
import qualified Control.Monad.Catch
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control

import qualified Data.Serialize as S
import qualified Network.Simple.TCP as N
import qualified Data.Set as Set
import qualified Data.List as L
import System.Random

import Raft.Client
import Raft.Event
import Raft.Types
import Examples.Raft.Socket.Common

import System.Console.Haskeline.MonadException (MonadException(..), RunIO(..))
import System.Timeout.Lifted (timeout)

data ClientSocketEnv
  = ClientSocketEnv { clientId :: ClientId
                    , clientSocket :: N.Socket
                    } deriving (Show)

newtype RaftSocketT m a
  = RaftSocketT { unRaftSocketT :: ReaderT ClientSocketEnv m a }
  deriving newtype ( Functor, Applicative, Monad, MonadIO, MonadReader ClientSocketEnv, Alternative, MonadPlus)

instance MonadTrans RaftSocketT where
  lift = RaftSocketT . lift

deriving instance MonadBase IO m => MonadBase IO (RaftSocketT m)

instance MonadTransControl RaftSocketT where
    type StT RaftSocketT a = StT (ReaderT ClientSocketEnv) a
    liftWith = defaultLiftWith RaftSocketT unRaftSocketT
    restoreT = defaultRestoreT RaftSocketT

instance MonadBaseControl IO m => MonadBaseControl IO (RaftSocketT m) where
    type StM (RaftSocketT m) a = ComposeSt RaftSocketT m a
    liftBaseWith = defaultLiftBaseWith
    restoreM     = defaultRestoreM

type RaftSocketClientM v = RaftClientT v (RaftSocketT IO)

-- This annoying instance is because of the Haskeline library, letting us use a
-- custom monad transformer stack as the base monad of 'InputT'. IMO it should
-- be automatically derivable. Why does haskeline use a custom exception
-- monad... ?
instance MonadException m => MonadException (RaftSocketT m) where
  controlIO f =
    RaftSocketT $ ReaderT $ \r ->
      controlIO $ \(RunIO run) ->
        let run' = RunIO (fmap (RaftSocketT . ReaderT . const) . run . flip runReaderT r . unRaftSocketT)
         in fmap (flip runReaderT r . unRaftSocketT) $ f run'

instance (S.Serialize v, MonadIO m) => RaftClientSend (RaftSocketT m) v where
  type RaftClientSendError (RaftSocketT m) v = Text
  raftClientSend nid creq = do
    let (host,port) = nidToHostPort nid
    eRes <-
      liftIO $ Control.Monad.Catch.try $ do
        putText $ "Trying to send to node " <> toS nid
        N.connect host port $ \(sock, sockAddr) ->
          N.send sock (S.encode (ClientRequestEvent creq))
        putText $ "Successfully sent to node " <> toS nid
    case eRes of
      Left (err :: SomeException) ->
        pure $ Left ("Failed to send ClientWriteReq: " <> show err)
      Right _ -> pure (Right ())

instance (S.Serialize s, MonadIO m) => RaftClientRecv (RaftSocketT m) s where
  type RaftClientRecvError (RaftSocketT m) s = Text
  raftClientRecv = do
    socketEnv@ClientSocketEnv{..} <- ask
    eRes <-
      fmap (first (show :: SomeException -> Text)) $
        liftIO $ Control.Monad.Catch.try $
          N.accept clientSocket $ \(sock', sockAddr') -> do
            recvSockM <- N.recv sock' (4 * 4096)
            case recvSockM of
              Nothing -> pure $ Left "Received empty data from socket"
              Just recvSock -> pure (first toS (S.decode recvSock))
    case join eRes of
      Left err ->
        pure $ Left ("Failed to receive ClientResponse: " <> err)
      Right res -> pure (Right res)

--------------------------------------------------------------------------------

runRaftSocketClientM :: ClientSocketEnv -> RaftSocketClientM v a -> IO a
runRaftSocketClientM socketEnv =
  flip runReaderT socketEnv . unRaftSocketT . runRaftClientT (clientId socketEnv) 0

-- | Randomly select a node from a set of nodes a send a message to it
selectRndNode :: NodeIds -> IO NodeId
selectRndNode nids =
  (Set.toList nids L.!!) <$> randomRIO (0, length nids - 1)

-- | Randomly read the state of a random node
sendReadRndNode :: (S.Serialize sm, S.Serialize v) => NodeIds -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendReadRndNode nids =
  liftIO (selectRndNode nids) >>= sendRead

-- | Like 'sendWriteRndNode' but with a timeout
sendReadRndNode_ :: (S.Serialize v, S.Serialize sm) => NodeIds -> Int -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendReadRndNode_ nids t = do
  mRes <- timeout t (sendReadRndNode nids)
  case mRes of
    Nothing -> pure (Left "Timeout: 'sendReadRndNode_")
    Just res -> pure res

-- | Randomly write to a random node
sendWriteRndNode :: (S.Serialize v, S.Serialize sm) => NodeIds -> v -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWriteRndNode nids cmd =
  liftIO (selectRndNode nids) >>= flip sendWrite cmd

-- | Like 'sendWriteRndNode' but with a timeout
sendWriteRndNode_ :: (S.Serialize v, S.Serialize sm) => NodeIds -> Int -> v -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWriteRndNode_ nids t cmd = do
  mRes <- timeout t (sendWriteRndNode nids cmd)
  case mRes of
    Nothing -> pure (Left "Timeout: 'sendWriteRndNode_")
    Just res -> pure res

-- | Request the state of a node, blocking until a response is received
sendRead :: forall v sm. (S.Serialize sm, S.Serialize v) => NodeId -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendRead nid = clientSendRead nid >> clientRecv

-- | Write to a node, blocking until a response is received
sendWrite :: (S.Serialize v, S.Serialize sm) => NodeId -> v -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWrite nid cmd = clientSendWrite nid cmd >> clientRecv

-- | Like 'sendRead' but with a timeout
sendRead_
  :: forall v sm. (S.Serialize sm, S.Serialize v)
  => NodeId
  -> Int
  -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendRead_ nid t = do
  mRes <- timeout t (sendRead nid)
  case mRes of
    Nothing -> pure (Left "Timeout: 'sendRead'")
    Just res -> pure res

-- | Like 'sendWrite' but with a timeout
sendWrite_
  :: forall v sm. (S.Serialize sm, S.Serialize v)
  => NodeId
  -> Int
  -> v
  -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWrite_ nid t cmd = do
  mRes <- timeout t (sendWrite nid cmd)
  case mRes of
    Nothing -> pure (Left "Timeout: 'sendWrite")
    Just res -> pure res

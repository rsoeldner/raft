{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module Examples.Raft.Socket.Client where

import Protolude

import qualified Control.Monad.Catch
import           Control.Monad.Trans.Class

import qualified Data.Serialize as S
import qualified Network.Simple.TCP as N
import qualified Data.Set as Set
import qualified Data.List as L
import System.Random

import Raft.Client
import Raft.Types
import Examples.Raft.Socket.Common

import System.Console.Haskeline.MonadException (MonadException(..), RunIO(..))


data ClientSocketEnv
  = ClientSocketEnv { clientId :: ClientId
                    , clientSocket :: N.Socket
                    } deriving (Show)

newtype RaftSocketT m a
  = RaftSocketT { unRaftSocketT :: ReaderT ClientSocketEnv m a }
  deriving newtype ( Functor, Applicative, Monad, MonadIO, MonadReader ClientSocketEnv, Alternative, MonadPlus)

instance MonadTrans RaftSocketT where
  lift = RaftSocketT . lift

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
      liftIO $ Control.Monad.Catch.try $
        N.connect host port $ \(sock, sockAddr) ->
          N.send sock (S.encode creq)
    case eRes of
      Left (err :: SomeException) ->
        pure $ Left ("Failed to send ClientWriteReq: " <> show err)
      Right _ -> pure (Right ())

instance (S.Serialize s, MonadIO m) => RaftClientRecv (RaftSocketT m) s where
  type RaftClientRecvError (RaftSocketT m) s = Text
  raftClientRecv = do
    socketEnv@ClientSocketEnv{..} <- ask
    eRes <-
      liftIO $ Control.Monad.Catch.try $
        N.accept clientSocket $ \(sock', sockAddr') -> do
          recvSockM <- N.recv sock' (4 * 4096)
          case recvSockM of
            Nothing -> pure $ Left "Received empty data from socket"
            Just recvSock -> pure (first toS (S.decode recvSock))
    case eRes of
      Left (err :: SomeException) ->
        pure $ Left ("Failed to send ClientWriteReq: " <> show err)
      Right _ -> pure (Right ())

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

-- | Randomly write to a random node
sendWriteRndNode :: (S.Serialize v, S.Serialize sm) => v -> NodeIds -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWriteRndNode cmd nids =
  liftIO (selectRndNode nids) >>= sendWrite cmd

-- | Request the state of a node. It blocks until the node responds
sendRead :: forall v sm. (S.Serialize sm, S.Serialize v) => NodeId -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendRead nid = clientSendRead nid >> clientRecv

-- | Write to a node. It blocks until the node responds
sendWrite :: (S.Serialize v, S.Serialize sm) => v -> NodeId -> RaftSocketClientM v (Either Text (ClientResponse sm))
sendWrite cmd nid = clientSendWrite nid cmd >> clientRecv

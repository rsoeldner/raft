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
import Raft.Event
import Raft.Types
import Examples.Raft.Socket.Common

import System.Console.Haskeline.MonadException (MonadException(..), RunIO(..))


data ClientSocketEnv
  = ClientSocketEnv { clientId :: ClientId
                    , clientSocket :: N.Socket
                    } deriving (Show)

newtype RaftSocketClientT v m a
  = RaftSocketClientT { unRaftSocketClientM :: RaftClientT v (ReaderT ClientSocketEnv m) a }
  deriving newtype ( Functor, Applicative, Monad, MonadIO)

instance MonadReader ClientSocketEnv (RaftSocketClientM v) where
  ask = ask

instance MonadTrans (RaftSocketClientT v) where
  lift = RaftSocketClientT . lift . lift

type RaftSocketClientM v = RaftSocketClientT v IO

-- deriving instance Alternative (RaftSocketClientM v)
-- deriving instance MonadPlus (RaftSocketClientM v)

-- This annoying instance is because of the Haskeline library, letting us use a
-- custom monad transformer stack as the base monad of 'InputT'. IMO it should
-- be automatically derivable. Why does haskeline use a custom exception
-- monad... ?
-- instance MonadException m => MonadException (RaftSocketClientT v m) where
--   controlIO f =
--     RaftSocketClientT $ ReaderT $ \r ->
--       controlIO $ \(RunIO run) ->
--         let run' = RunIO (fmap (RaftSocketClientT . ReaderT . const) . run . flip runReaderT r . unRaftSocketClientM)
--          in fmap (flip runReaderT r . unRaftSocketClientM) $ f run'

instance S.Serialize v => RaftClientSend (RaftSocketClientM v) v where
  type RaftClientSendError (RaftSocketClientM v) v = Text
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



--------------------------------------------------------------------------------

runRaftSocketClientM :: ClientSocketEnv -> RaftSocketClientM v a -> IO a
runRaftSocketClientM socketEnv =
  flip runReaderT socketEnv . runRaftClientT (clientId socketEnv) 0 . unRaftSocketClientM

-- | Randomly select a node from a set of nodes a send a message to it
selectRndNode :: NodeIds -> IO NodeId
selectRndNode nids =
  (Set.toList nids L.!!) <$> randomRIO (0, length nids - 1)

-- | Randomly read the state of a random node
sendReadRndNode :: (S.Serialize sm, S.Serialize v) => Proxy v -> NodeIds -> RaftSocketClientM v (Either [Char] (ClientResponse sm))
sendReadRndNode proxyV nids =
  liftIO (selectRndNode nids) >>= sendRead proxyV

-- | Randomly write to a random node
sendWriteRndNode :: (S.Serialize v, S.Serialize sm) => v -> NodeIds -> RaftSocketClientM v (Either [Char] (ClientResponse sm))
sendWriteRndNode cmd nids =
  liftIO (selectRndNode nids) >>= sendWrite cmd

-- | Request the state of a node. It blocks until the node responds
sendRead :: forall v sm. (S.Serialize sm, S.Serialize v) => Proxy v -> NodeId -> RaftSocketClientM v (Either [Char] (ClientResponse sm))
sendRead _  nid = do
  socketEnv@ClientSocketEnv{..} <- ask
  let (host, port) = nidToHostPort nid
  eRes <-
    liftIO $ Control.Monad.Catch.try $
      N.connect host port $ \(sock, sockAddr) -> N.send sock . S.encode $
        ClientRequestEvent (ClientRequest clientId ClientReadReq :: ClientRequest v)
  case eRes of
    Left (err :: SomeException) -> pure $ Left ("Failed to send ClientReadReq: " <> show err)
    Right _ -> acceptClientConnections

-- | Write to a node. It blocks until the node responds
sendWrite :: (S.Serialize v, S.Serialize sm) => v -> NodeId -> RaftSocketClientM v (Either [Char] (ClientResponse sm))
sendWrite cmd nid = do
  socketEnv@ClientSocketEnv{..} <- ask
  let (host, port) = nidToHostPort nid
  eRes <- RaftSocketClientT $ clientSendWrite nid cmd
  case eRes of
    Left err -> pure $ Left err
    Right _ -> acceptClientConnections

-- | Accept a connection and return the client response synchronously
acceptClientConnections :: S.Serialize sm => RaftSocketClientM v (Either [Char] (ClientResponse sm))
acceptClientConnections = do
  socketEnv@ClientSocketEnv{..} <- ask
  liftIO $ fmap (join . first (show :: SomeException -> [Char])) $ Control.Monad.Catch.try $
    N.accept clientSocket $ \(sock', sockAddr') -> do
      recvSockM <- N.recv sock' 4096
      case recvSockM of
        Nothing -> pure $ Left "Received empty data from socket"
        Just recvSock -> pure (S.decode recvSock)

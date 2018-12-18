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
import System.Random

import Raft.Client
import Raft.Event
import Raft.Types
import Examples.Raft.Socket.Common

import System.Console.Haskeline.MonadException (MonadException(..), RunIO(..))
import System.Timeout.Lifted (timeout)

newtype ClientSocket
  = ClientSocket { clientSocket :: N.Socket }
  deriving (Show)

newtype RaftSocketT m a
  = RaftSocketT { unRaftSocketT :: ReaderT ClientSocket m a }
  deriving newtype ( Functor, Applicative, Monad, MonadIO, MonadReader ClientSocket, Alternative, MonadPlus)

instance MonadTrans RaftSocketT where
  lift = RaftSocketT . lift

deriving instance MonadBase IO m => MonadBase IO (RaftSocketT m)

instance MonadTransControl RaftSocketT where
    type StT RaftSocketT a = StT (ReaderT ClientSocket) a
    liftWith = defaultLiftWith RaftSocketT unRaftSocketT
    restoreT = defaultRestoreT RaftSocketT

instance MonadBaseControl IO m => MonadBaseControl IO (RaftSocketT m) where
    type StM (RaftSocketT m) a = ComposeSt RaftSocketT m a
    liftBaseWith = defaultLiftBaseWith
    restoreM     = defaultRestoreM

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
        -- Warning: blocks if socket is allocated by OS, even though the socket
        -- may have been closed by the running process
        -- putText $ "Sending ClientReq to " <> toS nid <> "..."
        N.connect host port $ \(sock, sockAddr) ->
          N.send sock (S.encode (ClientRequestEvent creq))
        -- putText $ "Successfully sent ClientReq to " <> toS nid <> "!"
    case eRes of
      Left (err :: SomeException) ->
        pure $ Left ("Failed to send ClientWriteReq: " <> show err)
      Right _ -> pure (Right ())

instance (S.Serialize s, MonadIO m) => RaftClientRecv (RaftSocketT m) s where
  type RaftClientRecvError (RaftSocketT m) s = Text
  raftClientRecv = do
    socketEnv@ClientSocket{..} <- ask
    eRes <-
      fmap (first (show :: SomeException -> Text)) $
        liftIO $ Control.Monad.Catch.try $
          N.accept clientSocket $ \(sock', sockAddr') -> do
            recvSockM <- N.recv sock' (4 * 4096)
            N.closeSock sock'
            case recvSockM of
              Nothing -> pure $ Left "Received empty data from socket"
              Just recvSock -> pure (first toS (S.decode recvSock))
    case join eRes of
      Left err ->
        pure $ Left ("Failed to receive ClientResponse: " <> err)
      Right res -> pure (Right res)

--------------------------------------------------------------------------------

type RaftSocketClientM v = RaftClientT v (RaftSocketT IO)

runRaftSocketClientM
  :: ClientId
  -> Set NodeId
  -> ClientSocket
  -> RaftSocketClientM v a
  -> IO a
runRaftSocketClientM cid nids socketEnv rscm = do
  raftClientState <- initRaftClientState <$> liftIO newStdGen
  let raftClientEnv = RaftClientEnv cid
  flip runReaderT socketEnv
    . unRaftSocketT
    . runRaftClientT raftClientEnv raftClientState
    $ rscm

socketClientRead
  :: (S.Serialize s, S.Serialize v, Show (RaftClientError s v (RaftSocketClientM v)))
  => RaftSocketClientM v (Either Text (ClientResponse s))
socketClientRead = first show <$> clientReadTimeout 1000000

socketClientWrite
  :: (S.Serialize s, S.Serialize v, Show (RaftClientError s v (RaftSocketClientM v)))
  => v
  -> RaftSocketClientM v (Either Text (ClientResponse s))
socketClientWrite v = first show <$> clientWriteTimeout 1000000 v

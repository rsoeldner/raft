{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}

module Raft.Logging where

import Protolude

import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.State (modify')

import Data.Time

import Raft.NodeState
import Raft.Types


data LogCtx
  = LogCtx
    { logCtxDest :: LogDest
    , logCtxSeverity :: Severity
    }
  | NoLogs

-- | Representation of the logs' destination
data LogDest
  = LogFile FilePath
  | LogStdout

-- | Representation of the severity of the logs
data Severity
  = Debug     -- 1
  | Info      -- 2
  | Critical  -- 3
  deriving (Show, Eq)

data LogMsg = LogMsg
  { mTime :: Maybe UTCTime
  , severity :: Severity
  , logMsgData :: LogMsgData
  }

data LogMsgData = LogMsgData
  { logMsgNodeId :: NodeId
  , logMsgNodeState :: Mode
  , logMsg :: Text
  } deriving (Show)

logMsgToText :: LogMsg -> Text
logMsgToText (LogMsg mt s d) =
    maybe "" timeToText mt <> "(" <> show s <> ")" <> " " <> logMsgDataToText d
  where
    timeToText :: UTCTime -> Text
    timeToText t = "[" <> toS (timeToText' t) <> "]"

    timeToText' = formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S"))

logMsgDataToText :: LogMsgData -> Text
logMsgDataToText LogMsgData{..} =
  "<" <> toS logMsgNodeId <> " | " <> show logMsgNodeState <> ">: " <> logMsg

class Monad m => RaftLogger v m | m -> v where
  loggerCtx :: m (NodeId, RaftNodeState v)

mkLogMsgData :: RaftLogger v m => Text -> m (LogMsgData)
mkLogMsgData msg = do
  (nid, nodeState) <- loggerCtx
  let mode = nodeMode nodeState
  pure $ LogMsgData nid mode msg

instance RaftLogger v m => RaftLogger v (RaftLoggerT v m) where
  loggerCtx = lift loggerCtx

--------------------------------------------------------------------------------
-- Logging with IO
--------------------------------------------------------------------------------

logToDest :: MonadIO m => LogCtx -> LogMsg -> m ()
logToDest LogCtx{..} logMsg =
  case logCtxDest of
    LogStdout -> case logCtxSeverity of
      Debug -> putText (logMsgToText logMsg)
      Info -> if severity logMsg == Debug
                then pure ()
                else liftIO $ putText (logMsgToText logMsg)
      Critical -> if severity logMsg /= Critical
                    then pure ()
                    else liftIO $ putText (logMsgToText logMsg)
    LogFile fp -> case logCtxSeverity of
      Debug -> liftIO $ appendFile fp (logMsgToText logMsg <> "\n")
      Info -> if severity logMsg == Debug
                then pure ()
                else liftIO $ appendFile fp (logMsgToText logMsg <> "\n")
      Critical -> if severity logMsg /= Critical
                    then pure ()
                    else liftIO $ appendFile fp (logMsgToText logMsg <> "\n")
logToDest NoLogs _ = pure ()

logToStdout :: MonadIO m => Severity -> LogMsg -> m ()
logToStdout s = logToDest $ LogCtx LogStdout s

logToFile :: MonadIO m => FilePath -> Severity -> LogMsg -> m ()
logToFile fp s = logToDest $ LogCtx (LogFile fp) s

logWithSeverityIO :: forall m v. (RaftLogger v m, MonadIO m) => Severity -> LogCtx -> Text -> m ()
logWithSeverityIO s logDest msg = do
  logMsgData <- mkLogMsgData msg
  now <- liftIO getCurrentTime
  let logMsg = LogMsg (Just now) s logMsgData
  logToDest logDest logMsg

logInfoIO :: (RaftLogger v m, MonadIO m) => LogCtx -> Text -> m ()
logInfoIO = logWithSeverityIO Info

logDebugIO :: (RaftLogger v m, MonadIO m) => LogCtx -> Text -> m ()
logDebugIO = logWithSeverityIO Debug

logCriticalIO :: (RaftLogger v m, MonadIO m) => LogCtx -> Text -> m ()
logCriticalIO = logWithSeverityIO Critical

--------------------------------------------------------------------------------
-- Pure Logging
--------------------------------------------------------------------------------

newtype RaftLoggerT v m a = RaftLoggerT {
    unRaftLoggerT :: StateT [LogMsg] m a
  } deriving (Functor, Applicative, Monad, MonadState [LogMsg], MonadTrans)

runRaftLoggerT
  :: Monad m
  => RaftLoggerT v m a -- ^ The computation from which to extract the logs
  -> m (a, [LogMsg])
runRaftLoggerT = flip runStateT [] . unRaftLoggerT

type RaftLoggerM v = RaftLoggerT v Identity

runRaftLoggerM
  :: RaftLoggerM v a
  -> (a, [LogMsg])
runRaftLoggerM = runIdentity . runRaftLoggerT

logWithSeverity :: RaftLogger v m => Severity -> Text -> RaftLoggerT v m ()
logWithSeverity s txt = do
  !logMsgData <- mkLogMsgData txt
  let !logMsg = LogMsg Nothing s logMsgData
  modify' (++ [logMsg])

logInfo :: RaftLogger v m => Text -> RaftLoggerT v m ()
logInfo = logWithSeverity Info

logDebug :: RaftLogger v m => Text -> RaftLoggerT v m ()
logDebug = logWithSeverity Debug

logCritical :: RaftLogger v m => Text -> RaftLoggerT v m ()
logCritical = logWithSeverity Critical

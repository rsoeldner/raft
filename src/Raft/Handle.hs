{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

module Raft.Handle where

import Protolude

import Data.Serialize (Serialize)

import qualified Raft.Follower as Follower
import qualified Raft.Candidate as Candidate
import qualified Raft.Leader as Leader

import Raft.Action
import Raft.Event
import Raft.Monad
import Raft.NodeState
import Raft.Persistent
import Raft.RPC
import Raft.Types
import Raft.Logging (LogMsg)

-- | Main entry point for handling events
handleEvent
  :: forall sm v.
     (RSMP sm v, Show v, Serialize v)
  => RaftNodeState v
  -> TransitionEnv sm v
  -> PersistentState
  -> Event v
  -> (RaftNodeState v, PersistentState, [Action sm v], [LogMsg])
handleEvent raftNodeState@(RaftNodeState initNodeState) transitionEnv persistentState event =
    -- Rules for all servers:
    case handleNewerRPCTerm of
      ((RaftNodeState resNodeState, logMsgs), persistentState', outputs) ->
        case handleEvent' resNodeState transitionEnv persistentState' event of
          ((ResultState _ resultState, logMsgs'), persistentState'', outputs') ->
            (RaftNodeState resultState, persistentState'', outputs <> outputs', logMsgs <> logMsgs')
  where
    handleNewerRPCTerm :: ((RaftNodeState v, [LogMsg]), PersistentState, [Action sm v])
    handleNewerRPCTerm =
      case event of
        MessageEvent (RPCMessageEvent (RPCMessage _ rpc)) ->
          runTransitionM transitionEnv persistentState $ do
            -- If RPC request or response contains term T > currentTerm: set
            -- currentTerm = T, convert to follower
            currentTerm <- gets currentTerm
            if currentTerm < rpcTerm rpc
              then
                case convertToFollower initNodeState of
                  ResultState _ nodeState -> do
                    modify $ \pstate ->
                      pstate { currentTerm = rpcTerm rpc
                             , votedFor = Nothing
                             }
                    resetElectionTimeout
                    pure (RaftNodeState nodeState)
              else pure raftNodeState
        _ -> ((raftNodeState, []), persistentState, mempty)

    convertToFollower :: forall s. NodeState s v -> ResultState s v
    convertToFollower nodeState =
      case nodeState of
        NodeFollowerState _ ->
          ResultState HigherTermFoundFollower nodeState
        NodeCandidateState cs ->
          ResultState HigherTermFoundCandidate $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = csCommitIndex cs
              , fsLastApplied = csLastApplied cs
              , fsLastLogEntry = csLastLogEntry cs
              , fsTermAtAEPrevIndex = Nothing
              , fsFirstIndexStoredForTerm = index0
              , fsClientReqCache = csClientReqCache cs
              }
        NodeLeaderState ls ->
          ResultState HigherTermFoundLeader $
            NodeFollowerState FollowerState
              { fsCurrentLeader = NoLeader
              , fsCommitIndex = lsCommitIndex ls
              , fsLastApplied = lsLastApplied ls
              , fsLastLogEntry = lsLastLogEntry ls
              , fsTermAtAEPrevIndex = Nothing
              , fsFirstIndexStoredForTerm = lsCommitIndex ls
              , fsClientReqCache = lsClientReqCache ls
              }


data RaftHandler ns sm v = RaftHandler
  { handleAppendEntries :: RPCHandler ns sm (AppendEntries v) v
  , handleAppendEntriesResponse :: RPCHandler ns sm AppendEntriesResponse v
  , handleRequestVote :: RPCHandler ns sm RequestVote v
  , handleRequestVoteResponse :: RPCHandler ns sm RequestVoteResponse v
  , handleTimeout :: TimeoutHandler ns sm v
  , handleClientRequest :: ClientReqHandler ns sm v
  }

followerRaftHandler :: (Show v, Serialize v) => RaftHandler 'Follower sm v
followerRaftHandler = RaftHandler
  { handleAppendEntries = Follower.handleAppendEntries
  , handleAppendEntriesResponse = Follower.handleAppendEntriesResponse
  , handleRequestVote = Follower.handleRequestVote
  , handleRequestVoteResponse = Follower.handleRequestVoteResponse
  , handleTimeout = Follower.handleTimeout
  , handleClientRequest = Follower.handleClientRequest
  }

candidateRaftHandler :: (Show v, Serialize v) => RaftHandler 'Candidate sm v
candidateRaftHandler = RaftHandler
  { handleAppendEntries = Candidate.handleAppendEntries
  , handleAppendEntriesResponse = Candidate.handleAppendEntriesResponse
  , handleRequestVote = Candidate.handleRequestVote
  , handleRequestVoteResponse = Candidate.handleRequestVoteResponse
  , handleTimeout = Candidate.handleTimeout
  , handleClientRequest = Candidate.handleClientRequest
  }

leaderRaftHandler :: (Show v, Serialize v) => RaftHandler 'Leader sm v
leaderRaftHandler = RaftHandler
  { handleAppendEntries = Leader.handleAppendEntries
  , handleAppendEntriesResponse = Leader.handleAppendEntriesResponse
  , handleRequestVote = Leader.handleRequestVote
  , handleRequestVoteResponse = Leader.handleRequestVoteResponse
  , handleTimeout = Leader.handleTimeout
  , handleClientRequest = Leader.handleClientRequest
  }

mkRaftHandler :: forall ns sm v. (Show v, Serialize v) => NodeState ns v -> RaftHandler ns sm v
mkRaftHandler nodeState =
  case nodeState of
    NodeFollowerState _ -> followerRaftHandler
    NodeCandidateState _ -> candidateRaftHandler
    NodeLeaderState _ -> leaderRaftHandler

handleEvent'
  :: forall ns sm v.
     (RSMP sm v, Show v, Serialize v)
  => NodeState ns v
  -> TransitionEnv sm v
  -> PersistentState
  -> Event v
  -> ((ResultState ns v, [LogMsg]), PersistentState, [Action sm v])
handleEvent' initNodeState transitionEnv persistentState event =
    runTransitionM transitionEnv persistentState $ do
      case event of
        MessageEvent mev ->
          case mev of
            RPCMessageEvent rpcMsg -> handleRPCMessage rpcMsg
            ClientRequestEvent cr -> do
              handleClientRequest initNodeState cr
        TimeoutEvent _ tout -> do
          handleTimeout initNodeState tout
  where
    RaftHandler{..} = mkRaftHandler initNodeState

    handleRPCMessage :: RPCMessage v -> TransitionM sm v (ResultState ns v)
    handleRPCMessage (RPCMessage sender rpc) =
      case rpc of
        AppendEntriesRPC appendEntries ->
          handleAppendEntries initNodeState sender appendEntries
        AppendEntriesResponseRPC appendEntriesResp ->
          handleAppendEntriesResponse initNodeState sender appendEntriesResp
        RequestVoteRPC requestVote ->
          handleRequestVote initNodeState sender requestVote
        RequestVoteResponseRPC requestVoteResp ->
          handleRequestVoteResponse initNodeState sender requestVoteResp

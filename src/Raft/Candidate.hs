{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}

module Raft.Candidate (
    handleAppendEntries
  , handleAppendEntriesResponse
  , handleRequestVote
  , handleRequestVoteResponse
  , handleTimeout
  , handleClientRequest
) where

import Protolude

import qualified Data.Serialize as S
import qualified Data.Set as Set
import qualified Data.Sequence as Seq
import qualified Data.Map as Map

import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Action
import Raft.Persistent
import Raft.Log
import Raft.Config
import Raft.Transition
import Raft.Types

--------------------------------------------------------------------------------
-- Candidate
--------------------------------------------------------------------------------

handleAppendEntries :: RPCHandler 'Candidate sm (AppendEntries v) v
handleAppendEntries (NodeCandidateState candidateState@CandidateState{..}) sender AppendEntries {..} = do
  pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Candidate sm AppendEntriesResponse v
handleAppendEntriesResponse (NodeCandidateState candidateState) _sender _appendEntriesResp =
  pure $ candidateResultState Noop candidateState

handleRequestVote :: RPCHandler 'Candidate sm RequestVote v
handleRequestVote ns@(NodeCandidateState candidateState@CandidateState{..}) sender requestVote@RequestVote{..} = do
  currentTerm <- gets currentTerm
  send sender $
    SendRequestVoteResponseRPC $
      RequestVoteResponse currentTerm False
  pure $ candidateResultState Noop candidateState

-- | Candidates should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse
  :: forall sm v. (Show v, S.Serialize v)
  => RPCHandler 'Candidate sm RequestVoteResponse v
handleRequestVoteResponse (NodeCandidateState candidateState@CandidateState{..}) sender requestVoteResp@RequestVoteResponse{..} = do
  currentTerm <- gets currentTerm
  if  | Set.member sender csVotes -> pure $ candidateResultState Noop candidateState
      | not rvrVoteGranted -> pure $ candidateResultState Noop candidateState
      | otherwise -> do
          let newCsVotes = Set.insert sender csVotes
          cNodeIds <- asks (configNodeIds . nodeConfig)
          if not $ hasMajority cNodeIds newCsVotes
            then do
              let newCandidateState = candidateState { csVotes = newCsVotes }
              pure $ candidateResultState Noop newCandidateState
            else leaderResultState BecomeLeader <$> becomeLeader

  where
    hasMajority :: Set a -> Set b -> Bool
    hasMajority nids votes =
      Set.size votes >= Set.size nids `div` 2 + 1

    mkNoopEntry :: TransitionM sm v (Entry v)
    mkNoopEntry = do
      let lastLogEntryIdx = lastLogEntryIndex csLastLogEntry
      currTerm <- gets currentTerm
      nid <- asks (configNodeId . nodeConfig)
      pure Entry
        { entryIndex = succ lastLogEntryIdx
        , entryTerm  = currTerm
        , entryValue = NoValue
        , entryIssuer = LeaderIssuer (LeaderId nid)
        , entryPrevHash = hashLastLogEntry csLastLogEntry
        }

    becomeLeader :: TransitionM sm v (LeaderState v)
    becomeLeader = do
      currentTerm <- gets currentTerm
      -- In order for leaders to know which entries have been replicated or not,
      -- a "no op" log entry must be created at the start of the term. See
      -- "Client ineraction", Section 8, of https://raft.github.io/raft.pdf.
      noopEntry <- mkNoopEntry
      appendLogEntries (Seq.Empty Seq.|> noopEntry)
      broadcast $ SendAppendEntriesRPC
        AppendEntriesData
          { aedTerm = currentTerm
          , aedLeaderCommit = csCommitIndex
          , aedEntriesSpec = FromNewLeader noopEntry
          }
      resetHeartbeatTimeout
      cNodeIds <- asks (configNodeIds . nodeConfig)
      let lastLogEntryIdx = entryIndex noopEntry
      pure LeaderState
       { lsCommitIndex = csCommitIndex
       , lsLastApplied = csLastApplied
       , lsNextIndex = Map.fromList $
           (,lastLogEntryIdx) <$> Set.toList cNodeIds
       , lsMatchIndex = Map.fromList $
           (,index0) <$> Set.toList cNodeIds
       , lsLastLogEntry = csLastLogEntry
       , lsReadReqsHandled = 0
       , lsReadRequest = mempty
       , lsClientReqCache = csClientReqCache
       }

handleTimeout :: TimeoutHandler 'Candidate sm v
handleTimeout (NodeCandidateState candidateState@CandidateState{..}) timeout =
  case timeout of
    HeartbeatTimeout -> pure $ candidateResultState Noop candidateState
    ElectionTimeout ->
      candidateResultState RestartElection <$>
        startElection csCommitIndex csLastApplied csLastLogEntry csClientReqCache

-- | When candidates handle a client request, they respond with NoLeader, as the
-- very reason they are candidate is because there is no leader. This is done
-- instead of simply not responding such that the client can know that the node
-- is live but that there is an election taking place.
handleClientRequest :: ClientReqHandler 'Candidate sm v
handleClientRequest (NodeCandidateState candidateState) (ClientRequest clientId _) = do
  redirectClientToLeader clientId NoLeader
  pure (candidateResultState Noop candidateState)

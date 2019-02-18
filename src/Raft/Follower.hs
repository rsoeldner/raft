{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MonoLocalBinds #-}

module Raft.Follower (
    handleAppendEntries
  , shouldApplyAppendEntries
  , handleAppendEntriesResponse
  , handleRequestVote
  , handleRequestVoteResponse
  , handleTimeout
  , handleClientRequest
) where

import Protolude

import Data.Sequence (Seq(..))

import Raft.Action
import Raft.NodeState
import Raft.RPC
import Raft.Client
import Raft.Event
import Raft.Persistent
import Raft.Log (entryIndex)
import Raft.Transition
import Raft.Types

--------------------------------------------------------------------------------
-- Follower
--------------------------------------------------------------------------------

-- | Handle AppendEntries RPC message from Leader
-- Sections 5.2 and 5.3 of Raft Paper & Figure 2: Receiver Implementation
--
-- Note: see 'PersistentState' datatype for discussion about not keeping the
-- entire log in memory.
handleAppendEntries :: forall v sm. Show v => RPCHandler 'Follower sm (AppendEntries v) v
handleAppendEntries ns@(NodeFollowerState fs) sender ae@AppendEntries{..} = do
    PersistentState{..} <- get

    let status = shouldApplyAppendEntries currentTerm fs ae
    newFollowerState <-
      case status of
        AERSuccess -> do
          appendLogEntries aeEntries
          resetElectionTimeout
          pure $ updateFollowerState fs
        _ -> pure fs

    send (unLeaderId aeLeaderId) $
      SendAppendEntriesResponseRPC
        AppendEntriesResponse
          { aerTerm = currentTerm
          , aerStatus = status
          , aerReadRequest = aeReadRequest
          }

    pure (followerResultState Noop newFollowerState)
  where
    updateFollowerState :: FollowerState v -> FollowerState v
    updateFollowerState fs =
      if aeLeaderCommit > fsCommitIndex fs
        then updateLeader (updateCommitIndex fs)
        else updateLeader fs

    updateCommitIndex :: FollowerState v -> FollowerState v
    updateCommitIndex followerState =
      case aeEntries of
        Empty ->
          followerState { fsCommitIndex = aeLeaderCommit }
        _ :|> e ->
          let newCommitIndex = min aeLeaderCommit (entryIndex e)
          in followerState { fsCommitIndex = newCommitIndex }

    updateLeader :: FollowerState v -> FollowerState v
    updateLeader followerState = followerState { fsCurrentLeader = CurrentLeader (LeaderId sender) }

-- | Decide if entries given can be applied
shouldApplyAppendEntries :: Term -> FollowerState v -> AppendEntries v -> AppendEntriesResponseStatus
shouldApplyAppendEntries currentTerm fs AppendEntries{..} =
  if aeTerm < currentTerm
    -- 1. Reply false if term < currentTerm
    then AERStaleTerm
    else
      case fsTermAtAEPrevIndex fs of
        Nothing
          -- there are no previous entries
          | aePrevLogIndex == index0 -> AERSuccess
          -- the follower doesn't have the previous index given in the AppendEntriesRPC
          | otherwise -> AERInconsistent
              { aerFirstIndexStoredForTerm = fsFirstIndexStoredForTerm fs }
        Just entryAtAEPrevLogIndexTerm ->
          -- 2. Reply false if log doesn't contain an entry at
          -- prevLogIndex whose term matches prevLogTerm.
          if entryAtAEPrevLogIndexTerm /= aePrevLogTerm
            then AERInconsistent
              { aerFirstIndexStoredForTerm = fsFirstIndexStoredForTerm fs }
            else AERSuccess
              -- 3. If an existing entry conflicts with a new one (same index
              -- but different terms), delete the existing entry and all that
              -- follow it.
              --   &
              -- 4. Append any new entries not already in the log
              -- (`appendLogEntries aeEntries` accomplishes 3 & 4 see above in handleAppendEntries )
              -- 5. If leaderCommit > commitIndex, set commitIndex =
              -- min(leaderCommit, index of last new entry)

-- | Followers should not respond to 'AppendEntriesResponse' messages.
handleAppendEntriesResponse :: RPCHandler 'Follower sm AppendEntriesResponse v
handleAppendEntriesResponse (NodeFollowerState fs) _ _ =
  pure (followerResultState Noop fs)

handleRequestVote :: RPCHandler 'Follower sm RequestVote v
handleRequestVote ns@(NodeFollowerState fs) sender RequestVote{..} = do
    PersistentState{..} <- get
    let voteGranted = giveVote currentTerm votedFor
    when voteGranted $ do
      modify $ \pstate ->
        pstate { votedFor = Just sender }
      resetElectionTimeout
    send sender $
      SendRequestVoteResponseRPC $
        RequestVoteResponse
          { rvrTerm = currentTerm
          , rvrVoteGranted = voteGranted
          }
    pure $ followerResultState Noop fs
  where
    giveVote term mVotedFor =
      and [ term <= rvTerm
          , validCandidateId mVotedFor
          , validCandidateLog
          ]

    validCandidateId Nothing = True
    validCandidateId (Just cid) = cid == rvCandidateId

    -- Check if the requesting candidate's log is more up to date
    -- Section 5.4.1 in Raft Paper
    validCandidateLog =
      let (lastEntryIdx, lastEntryTerm) = lastLogEntryIndexAndTerm (fsLastLogEntry fs)
       in (rvLastLogTerm > lastEntryTerm)
       || (rvLastLogTerm == lastEntryTerm && rvLastLogIndex >= lastEntryIdx)

-- | Followers should not respond to 'RequestVoteResponse' messages.
handleRequestVoteResponse :: RPCHandler 'Follower sm RequestVoteResponse v
handleRequestVoteResponse (NodeFollowerState fs) _ _  =
  pure (followerResultState Noop fs)

-- | Follower converts to Candidate if handling ElectionTimeout
handleTimeout :: TimeoutHandler 'Follower sm v
handleTimeout ns@(NodeFollowerState fs) timeout =
  case timeout of
    ElectionTimeout -> do
      logDebug "Follower times out. Starts election. Becomes candidate"
      candidateResultState StartElection <$>
        startElection (fsCommitIndex fs) (fsLastApplied fs) (fsLastLogEntry fs) (fsClientReqCache fs)
    -- Follower should ignore heartbeat timeout events
    HeartbeatTimeout -> pure (followerResultState Noop fs)

-- | When a client handles a client request, it redirects the client to the
-- current leader by responding with the current leader id, if it knows of one.
handleClientRequest :: ClientReqHandler 'Follower sm v
handleClientRequest (NodeFollowerState fs) (ClientRequest clientId _)= do
  redirectClientToLeader clientId (fsCurrentLeader fs)
  pure (followerResultState Noop fs)


{-# LANGUAGE GADTs #-}
module TestFollower where

import Protolude

import Test.Tasty
import Test.Tasty.HUnit
import Raft.Follower
import Raft.RPC
import Raft.NodeState



--test_handleAppendEntries :: [TestTree]
--test_handleAppendEntries =
  --[ testGroup
      --"shouldApplyAppendEntries"
      --[ testCase "1. AERStaleTerm if AE term < current term" $
          --shouldApplyAppendEntries 2 r (AppendEntries )@?= AERStaleTerm
      --, testCase "2. AERStaleTerm if AE term < current term" $ True @?= True
      --]
  --]
  --where
    --r = initRaftFollowerState

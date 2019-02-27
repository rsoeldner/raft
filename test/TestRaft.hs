{-# LANGUAGE GADTs #-}
module TestRaft where
import Protolude hiding
  (STM, TVar, TChan, newTChan, readMVar, readTChan, writeTChan, atomically, killThread, ThreadId, readTVar, writeTVar)


import Control.Monad.Catch
import Control.Monad.Conc.Class
import Control.Concurrent.Classy.STM.TVar
import Data.Sequence (Seq(..), (><), dropWhileR, (!?), singleton,)
import qualified Data.Sequence as Seq
import qualified Data.Map as Map
import Test.Tasty.HUnit
import Test.Tasty

import Raft
import Raft.Client
import Raft.Log
import Raft.Monad
import Raft.Types

import RaftTestT
import TestUtils



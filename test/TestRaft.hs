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

--idx1, idx2, idx3, idx3' :: Entry StoreCmd
--idx1 = Entry (Index 1)
      --(Term 1)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx2 = Entry (Index 2)
      --(Term 2)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx3 = Entry (Index 3)
      --(Term 3)
      --NoValue
      --(LeaderIssuer (LeaderId node0))
      --genesisHash

--idx3' = Entry (Index 3)
        --(Term 3)
        --(EntryValue $ Set "x" 2)
        --(LeaderIssuer (LeaderId node1))
        --genesisHash


genEntries :: Integer -> Integer -> [Entry StoreCmd]
genEntries numTerms numEntriesPerTerm =
  fmap gen (zip indexes terms)
 where
  indexes = [1 .. numTerms * numEntriesPerTerm]
  terms = concatMap (replicate (fromInteger numEntriesPerTerm)) [1 .. numTerms]
  gen (i, t) = Entry (Index (fromInteger i))
                     (Term (fromInteger t))
                     NoValue
                     (LeaderIssuer (LeaderId node0))
                     genesisHash


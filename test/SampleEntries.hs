module SampleEntries where
import Protolude
import qualified Data.Sequence as Seq

import Raft
import Raft.Log

import RaftTestT
import TestUtils

--------------------------------------------------------------------------------
-- Sample entries
--------------------------------------------------------------------------------
entries :: Entries StoreCmd
entries = genEntries 4 3  -- 4 terms, each with 3 entries

entriesMutated :: Entries StoreCmd
entriesMutated = fmap
  (\e -> if entryIndex e == Index 12
    then e { entryIssuer = LeaderIssuer (LeaderId node1)
           , entryValue  = EntryValue $ Set "x" 2
           }
    else e
  )
  entries

expectedStates =
  ( Term 5
  , entries
    Seq.|> Entry (Index 13)
                 (Term 5)
                 NoValue
                 (LeaderIssuer (LeaderId node0))
                 genesisHash
  )


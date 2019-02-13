<p align="center">
  <a href="http://www.adjoint.io"><img src="https://www.adjoint.io/assets/img/adjoint-logo@2x.png" width="250"/></a>
</p>

[![CircleCI](https://circleci.com/gh/adjoint-io/raft.svg?style=svg&circle-token=71138966721e3459d81362f6f379a4782a3f6b7d)](https://circleci.com/gh/adjoint-io/raft)

# Raft

Adjoint's implementation of the Raft consensus algorithm. See [original
paper](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf)
for further details about the protocol.

# Overview

Raft proposes a strong single-leader approach to consensus. It simplifies
operations, as there are no conflicts, while being more efficient than other
leader-less approaches due to the high throughput achievable by the leader. In
this leader-driven consensus algorithm, clients must contact the leader directly
in order to communicate with the system. The system needs to have an
elected leader in order to be available.

In addition to a pure core event loop, this library uses the systematic
concurrency testing library
[dejafu](https://hackage.haskell.org/package/dejafu-1.11.0.3) to test
certain properties about streams of events throughout the system. Random thread
interleavings are generated in a raft network and realistic event
streams are delivered to each node's event queue. We test for the absence of
deadlocks and exceptions, along with checking that the convergent state of the
system matches the expected results. These concurrency tests can be found
[here](https://github.com/adjoint-io/raft/blob/master/test/TestDejaFu.hs).

## Ensuring valid transitions between node states

Each server in Raft can only be in one of these three states:

- Leader: Active node that handles all client interactions and send
  AppendEntries RPCs to all other nodes.
- Candidate: Active node that attempts to become a leader.
- Follower: Passive node that just responds to RPCs.

Temporal (e.g. ElectionTimeout) and spatial (e.g. AppendEntries or RequestVote)
events cause nodes to transition from one state to another.

```
    [0]                     [1]                       [2]
------------> Follower --------------> Candidate --------------> Leader
               ^  ^                       |                        |
               |  |         [3]           |                        |
               |  |_______________________|                        |
               |                                                   |
               |                                 [4]               |
               |___________________________________________________|

- [0] Starts up | Recovers
- [1] Times out | Starts election
- [2] Receives votes from majority of servers and becomes leader
- [3] Discovers leader of new term | Discovers candidate with a higher term
- [4] Discovers server with higher term
```

All nodes in the Raft protocol begin in the follower state. A follower will stay
a follower unless it fails to hear from a leader or a candidate requesting a
vote within its ElectionTimeout timer. If this happens, a follower will
transition to a candidate state. These node states are illustrated in the type:

```haskell
data Mode
  = Follower
  | Candidate
  | Leader
```

The volatile state a node keeps track of may vary depending on the mode that it
is in. Using `DataKinds` and `GADTs`, we relate these specific node state
datatypes that contain the relevant data to the current node's mode with the
`NodeState` type. This way, we can enforce that the volatile state carried by a
node in mode `Follower` is indeed `FollowerState`, etc:

```haskell
-- | The volatile state of a Raft node
data NodeState (a :: Mode) v where
  NodeFollowerState :: FollowerState v -> NodeState 'Follower v
  NodeCandidateState :: CandidateState v -> NodeState 'Candidate v
  NodeLeaderState :: LeaderState v -> NodeState 'Leader v
```

The library's main event loop is comprised of a simple flow: Raft nodes receive
events on an STM channel, handle the event depending on the current node state,
return a list of actions to perform, and then perform those actions in the order
they were generated. The `Event` type specifies the main value to which raft
nodes react to, whereas the `Action` type specifies the action the raft node
performs as a result of the pairing of the current node state and received
event.

The Raft protocol has constraints on how nodes transition from one state to
another. For example, a follower cannot transition to a leader state
without first transitioning to a candidate state. Similarly, a leader can
never transition directly to a candidate state due to the algorithm
specification. Candidates are allowed to transition to any other node state.

To adhere to the Raft specification, we make use of some type level programming
to ensure that only valid transitions happen between node states.

```haskell
-- | All valid state transitions of a Raft node
data Transition (init :: Mode) (res :: Mode) where
  StartElection            :: Transition 'Follower 'Candidate
  HigherTermFoundFollower  :: Transition 'Follower 'Follower

  RestartElection          :: Transition 'Candidate 'Candidate
  DiscoverLeader           :: Transition 'Candidate 'Follower
  HigherTermFoundCandidate :: Transition 'Candidate 'Follower
  BecomeLeader             :: Transition 'Candidate 'Leader

  HandleClientReq          :: Transition 'Leader 'Leader
  SendHeartbeat            :: Transition 'Leader 'Leader
  DiscoverNewLeader        :: Transition 'Leader 'Follower
  HigherTermFoundLeader    :: Transition 'Leader 'Follower

  Noop :: Transition init init
```

To compose the `Transition` with the resulting state from the event handler, we
use the `ResultState` datatype, existentially quantifying the result state mode:

```haskell
-- | Existential type hiding the result type of a transition, fixing the
-- result state to the state dictated by the 'Transition init res' value.
data ResultState init v where
  ResultState :: Transition init res -> NodeState res -> ResultState init
```

This datatype fixes the result state to be dependent on the transition that
occurred; as long as the allowed transitions are correctly denoted in the
`Transition` data constructors, only valid transitions can be specified by the
`ResultState`. Furthermore, `ResultState` values existentially hide the result
state types, that can be accessed via pattern matching. Thus, all event
handlers, be they RPC handlers, timeout handlers, or client request handlers,
have a type signature of the form:

```haskell
handler :: NodeState init -> ... relevant handler data ... -> ResultState init
```

Statically, the `ResultState` will enforce that invalid transitions are not made
when writing handlers for all combinations of raft node modes and events. In the
future, this approach may be extended to limit the actions a node can emit
dependent on its current mode.

## Library Architecture

Within the Raft protocol, there is a pure core that can be abstracted without
the use of global state. The protocol can be looked at simply as a series
of function calls of a function from an initial node state to a result node
state. However, sometimes these transitions have *side effects*. In this library
we have elected to separate the *pure* and **effectful** layers.

The core event handling loop is a *pure* function that, given the current node
state and a few extra bits of global state, computes a list of `Action`s for the
effectful layer to perform (updating global state, sending a message to another
node over the network, etc.).

### Pure Layer

In order to update the replicated state machine, clients contact the leader via
"client requests" containing commands to be committed to the replicated state
machine. Once a command is received, the current leader assesses whether it is
possible to commit the command to the replicated state machine.

The replicated state machine must be deterministic such that every command
committed by a leader to the state machine will eventually be replicated on
every node in the network at the same index.

As the only part of the internal event loop that needs to be specified manually,
We ask users of our library to provide an instance of the state machine `RaftStateMachinePure`
typeclass. This typeclass relates a state machine type to a command type
and a single type class function `applyCmdRaftStateMachinePure`, a pure function that
should return the result of applying the command to the initial state machine.

```haskell
class RaftStateMachinePure sm v | sm -> v where
  data RaftStateMachinePureError sm v
  type RaftStateMachinePureCtx sm v = ctx | ctx -> sm v
  applyCmdRaftStateMachinePure :: RaftStateMachinePureCtx sm v -> sm -> v -> Either (RaftStateMachinePureError sm v) sm
```

Everything else related to the core event handling loop is not exposed to
library users. All that needs to be specified is the type of the state machine,
the commands to update it, and how to perform those updates.

### Effectful Layers

In this Raft implementation, there are four components that need access to global
state and system resources. Firstly, raft nodes must maintain some persistent
state for efficient and correct recovery from network outages or partitions.
Secondly, raft nodes need to send messages to other raft nodes for the network
(the replicated state machine) to be operational. Next, library users must
specify what event channel datastructure to use. Finally, the programmer must
provide a way to fork threads and run a list of effectful actions concurrently.

The reasons for the latter two design decisions-- requiring the programmer to
provide an event channel type and new/read/writeChannel primitives, a way to
fork an effectful action to run concurrently, and a way to run a list of actions
concurrently-- is a result of property based concurrency testing that we do,
found in `test/TestDejaFu.hs`. In order to test the system as a whole, to run
several nodes concurrently and test invariants about the system such as the
absence of deadlocks, we must be able to swap out the base monad for the
`ConcIO` monad, which has implementations of concurrency primitives that act
deterministically. This allows us to test that the raft nodes run correctly in 
a wide space of thread interleavings giving us more confidence that our code is
correct, assuming "correct" implementations of the `MonadRaftFork` and
`MonadRaftChan` typeclasses.

#### Persistent State

Each node persists data to disk, including the replicated log
entries. Since persisting data is an action that programmers have many opinions
and preferences regarding, we provide two type classes that abstract the
specifics of writing log entries to disk as well as a few other small bits of
relevant data. These are separated due to the nature in which the log entries
are queried, often by specific index and without bounds. Thus, it may be
desirable to store the log entries in an efficient database. The remaining
persistent data is always read and written atomically, and has a much smaller
storage footprint.

The actions of reading or modifying existing log entries on disk is broken down
even further: we ask the user to specify how to write, delete, and read
log entries from disk. Often these types of operations can be optimized via
smarter persistent data solutions like modern SQL databases, thus we arrive at
the following level of granularity:

```haskell
-- | The type class specifying how nodes should write log entries to storage.
class Monad m => RaftWriteLog m v where
  type RaftWriteLogError m
  -- | Write the given log entries to storage
  writeLogEntries
    :: Exception (RaftWriteLogError m)
    => Entries v -> m (Either (RaftWriteLogError m) ())

-- | The type class specifying how nodes should delete log entries from storage.
class Monad m => RaftDeleteLog m v where
  type RaftDeleteLogError m
  -- | Delete log entries from a given index; e.g. 'deleteLogEntriesFrom 7'
  -- should delete every log entry
  deleteLogEntriesFrom
    :: Exception (RaftDeleteLogError m)
    => Index -> m (Either (RaftDeleteLogError m) (Maybe (Entry v)))

-- | The type class specifying how nodes should read log entries from storage.
class Monad m => RaftReadLog m v where
  type RaftReadLogError m
  -- | Read the log at a given index
  readLogEntry
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Maybe (Entry v)))
  -- | Read log entries from a specific index onwards
  readLogEntriesFrom
    :: Exception (RaftReadLogError m)
    => Index -> m (Either (RaftReadLogError m) (Entries v))
  -- | Read the last log entry in the log
  readLastLogEntry
    :: Exception (RaftReadLogError m)
    => m (Either (RaftReadLogError m) (Maybe (Entry v)))
```

---

To read and write the `PersistentData` type (the remaining persistent data that
is not log entries), we ask the user to use the following `RaftPersist`
typeclass.

```haskell
-- | The RaftPersist type class specifies how to read and write the persistent
-- state to disk.
class Monad m => RaftPersist m where
  type RaftPersistError m
  readPersistentState
    :: Exception (RaftPersistError m)
    => m (Either (RaftPersistError m) PersistentState)
  writePersistentState
    :: Exception (RaftPersistError m)
    => PersistentState -> m (Either (RaftPersistError m) ())
```

### Networking

The other non-deterministic, effectful part of the protocol is the communication
between nodes over the network. It can be unreliable due to network delays,
partitions and packet loss, duplication and reordering, but the Raft consensus
algorithm was designed to achieve consensus in such harsh conditions.

The actions that must be performed in the networking layer are *sending RPCs* to
other raft nodes, *receiving RPCs* from other raft nodes, *sending client
responses* to clients who have issued requests, and *receiving client requests*
from clients wishing to update the replicated state. Depending on use of this
raft library, the two pairs are not necessary symmetric and so we do not
force the user into specifying a single way to send/receive messages to and from
raft nodes or clients.

We provide several type classes for users to specify the networking layer
themselves. The user must make sure that the `sendRPC`/`receiveRPC` and
`sendClient`/`receiveClient` pairs perform complementary actions; that an RPC
sent from one raft node to another is indeed receivable via `receiveRPC` on the
node to which it was sent:

```haskell
-- | Interface for nodes to send messages to one
-- another. E.g. Control.Concurrent.Chan, Network.Socket, etc.
class RaftSendRPC m v where
  sendRPC :: NodeId -> RPCMessage v -> m ()

-- | Interface for nodes to receive messages from one
-- another
class RaftRecvRPC m v where
  type RaftRecvRPCError m v
  receiveRPC :: m (Either (RaftRecvRPCError m v) (RPCMessage v))

-- | Interface for Raft nodes to send messages to clients
class RaftSendClient m sm v where
  sendClient :: ClientId -> ClientResponse sm v -> m ()

-- | Interface for Raft nodes to receive messages from clients
class RaftRecvClient m v where
  type RaftRecvClientError m v
  receiveClient :: m (Either (RaftRecvClientError m v) (ClientRequest v))
```

We have written a default implementation for network sockets over TCP in
[src/Examples/Raft/Socket](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/Socket)

### Event Channel

The core of the effectful layers of this Raft implmentation is the _event
channel_. Since different data channels have different performance, we ask the
programmer to supply an implementation of such a channel via yet another type
class and type family:

```haskell
class Monad m => MonadRaftChan v m where
  type RaftEventChan v m
  readRaftChan :: RaftEventChan v m -> m (Event v)
  writeRaftChan :: RaftEventChan v m -> Event v -> m ()
  newRaftChan :: m (RaftEventChan v m)
```

On spawning a raft node, the program will create a new event channel using
`newRaftChan`. Then, the event producers will be forked; These event producers
will use the aforementioned typeclasses like `RaftRecvRPC` and `RaftRecvClient`
to wait for messages from other raft nodes or clients wishing to contact the
node. Once a message is received, a message event is constructed from the
message contents and written to the main event channel via `writeRaftChan`. In
the main thread, the core event handler will be repeatedly reading events from
the event channel using `readRaftChan` and performing the correct action in
response to each event.

### Concurrency

The last of the type class instances the programmer must provide for the monad
they are running the raft node in is a `MonadRaftFork`, which provides the main
raft loop with the ability to fork a concurrent action; The raft node needs to
know how to fork actions in the monad. This is necessary for the raft node to 
be able to fork its event producers, and run other actions concurrently; e.g.
a leader responding to all followers at the same time during a heartbeat RPC
broadcast. The typeclass is defined as follows:

```haskell
-- | The typeclass encapsulating the concurrency operations necessary for the
-- implementation of the main event handling loop.
class Monad m => MonadRaftFork m where
  type RaftThreadId m
  raftFork
    :: RaftThreadRole      -- ^ The role of the current thread being forked
    -> m ()                -- ^ The action to fork
    -> m (RaftThreadId m)
```

The implementation of this typeclass is a bit subtle, and it is advised that
programmers do not implement it from scratch themselves. A default 
implementation is provided for the `IO` type using standard concurrency 
primitives making it easy for the programmer to simply rely on that
implementation. An example instance of this type class for a custom monad
transformer stack with `IO` the bottom:

```haskell
instance MonadRaftFork MyMonad where
  type RaftThreadId MyMonad = RaftThreadId IO
  raftFork threadRole myMonad = 
    lift $ raftFork threadRole (runMyMonad myMonad) 
```

The last thing to mention about this typeclass is the `RaftThreadRole` value
that must be passed to invocations of the `raftFork` function. In some
applications (and, noteably our concurrency testing suite) thread names can be
used for debugging and even message passing purposes. For instance of
`MonadRaftFork` that do not need to distinguish threads by name, simply ignore
the argument. 

# The Raft Example (`raft-example`)

In this library we provide a full fledged, non-production ready, example
implementation/s of monad transformers and type class instances for _all_ type
classes necessary to run a raft node. They can be found in
`src/Examples/Raft/...` or in `app/Main.hs`:

`RaftExampleT` (found in `app/Main.hs`):
- `MonadRaftFork`
- `MonadRaftChan`
- `RaftStateMachine`

`RaftSocketT` (found in `src/Examples/Raft/Socket/Node.hs`):
- `RaftSendRPC`
- `RaftRecvRPC`
- `RaftSendClient`
- `RaftRecvClient`

`RaftLogFileStoreT` (found in `src/Examples/Raft/FileStore/Log.hs`):
- `RaftReadLog`
- `RaftWriteLog`
- `RaftDeleteLog`
- `RaftInitLog`

`RaftPersistFileStoreT` (found in `src/Examples/Raft/FileStore/Persistent.hs`):
- `RaftPersistent`

Programmers can use these files and implementations for references when implementing 
the necessary type class instances for their bespoke monads, or even use some of
the monad transformers in their own stack!

We provide a complete example of the library where nodes communicate via network
sockets, and they write their logs on text files. See
[app/Main.hs](https://github.com/adjoint-io/raft/blob/master/app/Main.hs) to
have further insight.

1) Build the example executable:
```$ stack build ```

2) In separate terminals, run some raft nodes:

    The format of the cmd line invocation is:
    ``` 
    $ raft-example node <fresh/existing> <file/postgres> <node-id> <peer-1-node-id> ... <peer-n-node-id> 
    
    ```

    We are going to run a network of three nodes:

    - On terminal 1:

    ```$ stack exec raft-example node fresh file localhost:3001 localhost:3002 localhost:3003```

    - On terminal 2:

    ```$ stack exec raft-example node fresh file localhost:3002 localhost:3001 localhost:3003```

    - On terminal 3:

    ```$ stack exec raft-example node fresh file localhost:3003 localhost:3001 localhost:3002```

    The first node spawned should become candidate once its election's timer
    times out and request votes to other nodes. It will then become the leader,
    once it receives a majority of votes and will broadcast messages to all
    nodes at each heartbeat.

    **Note:** If you want to run a raft example node with _existing_ persistent data,
    pass the `existing` command line option to the `raft-example` program instead
    of `fresh`:
    
    ```$ stack exec raft-example node existing ...```


    **Note:** The example also runs using a PostgreSQL database as long as a
    user 'libraft_test' with password 'libraft_test' exists in your local
    postgresql installation. For ease of experimentation, if such a user does
    not exist, create it like so:

    ```$ sudo -su postgres psql -U postgres -c "CREATE USER libraft_test WITH CREATEDB PASSWORD 'libraft_test';"```

3) Run a client:
```$ stack exec raft-example client```

    In the example provided, there are five basic operations:

      - `addNode <host:port>`: Add a nodeId to the set of nodeIds that the client
        will communicate with. Adding a single node will be sufficient, as this node
        will redirect the command to the leader in case he is not.

      - `getNodes`: Return all node ids that the client is aware of.

      - `read`: Return the state of the leader.

      - `set <var> <val>`: Set a variable to a specific value.

      - `incr <var>`: Increment the value of a variable.

    Assuming that two nodes are run as mentioned above, a valid client workflow
    would be:
    ```
    >>> addNode localhost:3001
    >>> set testVar 4
    >>> incr testVar
    >>> read
    ```

    It will return the state of the leader's state machine (and eventually the state
    of all nodes in the Raft network). In our example, it will be a map of a single
    key `testVar` of value `4`

## How to use this library

1. [Define the state
machine](https://github.com/adjoint-io/raft#define-the-state-machine)
2. [Implement the networking
layer](https://github.com/adjoint-io/raft#implement-the-networking-layer)
3. [Implement the persistent
layer](https://github.com/adjoint-io/raft#implement-the-persistent-layer)
4. [Putting it all
together](https://github.com/adjoint-io/raft#putting-it-all-together)

### Define the state machine

The only requirement for our state machine is to instantiate the state machine `RaftStateMachinePure`
type class.

```haskell
-- | Interface to handle commands in the underlying state machine. Functional
--dependency permitting only a single state machine command to be defined to
--update the state machine.
class RaftStateMachinePure sm v | sm -> v where
  data RaftStateMachinePureError sm v
  type RaftStateMachinePureCtx sm v = ctx | ctx -> sm v
  rsmTransition :: RaftStateMachinePureCtx sm v -> sm -> v -> Either (RaftStateMachinePureError sm v) sm
  
```

In our [example](https://github.com/adjoint-io/raft/blob/master/app/Main.hs) we
use a simple map as a store whose values can only increase.

### Implement the networking layer

We leave the choice of the networking layer open to the user, as it can vary
depending on the use case (E.g. TCP/UDP/cloud-haskell/etc).

We need to specify how nodes will communicate with clients and with each other.
As described above in the [Networking
section](https://github.com/adjoint-io/raft#networking), it suffices to
implement those four type classes (`RaftSendRPC`, `RaftRecvRPC`,
`RaftSendClient`, `RaftRecvClient`).

In our example, we provide instances of nodes communicating over TCP to other
nodes
([Socket/Node.hs](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/Socket/Node.hs))
and clients
([Socket/Client.hs](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/Socket/Client.hs)).

Note that our datatypes will need to derive instances of `MonadThrow`,
`MonadCatch`, `MonadMask` and `MonadConc`. This allows us to test concurrent
properties of the system, using randomized thread scheduling to assert the
absence of deadlocks and exceptions.

In case of the `RaftSocketT` data type used in our example:

```haskell
deriving instance MonadConc m => MonadThrow (RaftSocketT v m)
deriving instance MonadConc m => MonadCatch (RaftSocketT v m)
deriving instance MonadConc m => MonadMask (RaftSocketT v m)
deriving instance MonadConc m => MonadConc (RaftSocketT v m)
```

### Implement the persistent layer

There are many different possibilities when it comes to persist data to disk, so
we also leave the specification open to the user.

As explained in the [Persistent
State](https://github.com/adjoint-io/raft#persistent-state) section above, we
will create instances for `RaftReadLog`, `RaftWriteLog` and
`RaftDeleteLog` to specify how we will read, write and
delete log entries, as well as `RaftPersist`. There are actually several data
that must be stored on disk; 1) the data the raft paper calls "persistent data"
and 2) the log entries of the node.

We provide an implementation that stores the persistent data in a file in
[src/Examples/Raft/FileStore/Persistent.hs](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/FileStore/Persistent.hs)

An example of storing log entries in a single file (for ease of implementation
in lieu of good performance for reads/writes) can be found in
[src/Examples/Raft/FileStore/Log.hs](https://github.com/adjoint-io/raft/blob/master/src/Examples/Raft/FileStore/Log.hs)

Lastly, a more "production ready" example of log entry storage using a
PostgreSQL database can be found in [src/Raft/Log/PostgreSQL.hs](https://github.com/adjoint-io/raft/blob/master/src/Raft/Log/PostgreSQL.hs).
This implementation is used in our `quickcheck-state-machine` model testing
module and is thus thoroughly tested. 

### Putting it all together

The last step is wrapping our previous data types that deal with
networking and persistent data into a single monad that also derives instances
of all the Raft type classes described (`RaftSendRPC`, `RaftRecvRPC`,
`RaftSendClient`, `RaftRecvClient`, `RaftReadLog`, `RaftWriteLog`,
`RaftDeleteLog` and `RaftPersist`).

In our example, this monad is `RaftExampleM sm v`. See
[app/Main.hs](https://github.com/adjoint-io/raft/blob/master/app/Main.hs).

Finally, we are ready to run our Raft nodes. We call the `runRaftNode` function
from the
[src/Raft.hs](https://github.com/adjoint-io/raft/blob/master/src/Raft.hs)
file, together with the function we define to run the stack of monads that
derive our Raft type classes.

# Test suite dependencies

The test suite depends on libfiu (commonly installed with package `fiu-utils`), 
which it uses to simulate network failures. In addition, the test suite also
depends on libpq-dev and postgresql. Furthermore, in order to successfully run
the model tests (which will run autmatically when executing `stack test`, but
fail immediately with "Failed to spawn node), you will have to run the following
command:

```
$ sudo -su postgres psql -U postgres -c "CREATE USER libraft_test WITH CREATEDB PASSWORD 'libraft_test';" 
```

# References

1. Ongaro, D., Ousterhout, J. [In Search of an Understandable Consensus
   Algorithm](https://raft.github.io/raft.pdf), 2014

2. Howard, H. [ARC: Analysis of Raft
   Consensus](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-857.pdf) 2014

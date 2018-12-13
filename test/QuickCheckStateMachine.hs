{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE PolyKinds          #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StandaloneDeriving #-}

module QuickCheckStateMachine where

import           Control.Concurrent            (threadDelay)
import           Control.Exception             (bracket)
import           Control.Monad.IO.Class        (liftIO)
import           Data.Bifunctor                (bimap)
import           Data.Char                     (isDigit)
import           Data.List                     (isInfixOf, (\\))
import           Data.Maybe                    (isJust)
import           Data.TreeDiff                 (ToExpr)
import           GHC.Generics                  (Generic, Generic1)
import           Prelude                       hiding (notElem)
import           System.Directory              (removePathForcibly)
import           System.IO                     (BufferMode (NoBuffering),
                                                Handle, IOMode (WriteMode),
                                                hClose, hGetLine, hPutStrLn,
                                                hPutStrLn, hSetBuffering,
                                                openFile)
import           System.Process                (ProcessHandle, StdStream (CreatePipe, UseHandle),
                                                callCommand, createProcess_,
                                                getPid, getProcessExitCode,
                                                proc, std_err, std_in, std_out,
                                                terminateProcess)
import           System.Timeout                (timeout)
import           Test.QuickCheck               (Gen, Property, arbitrary,
                                                elements, frequency,
                                                noShrinking, shrink,
                                                verboseCheck, withMaxSuccess,
                                                (===))
import           Test.QuickCheck.Monadic       (monadicIO)
import           Test.StateMachine             (Concrete, GenSym, Logic (..),
                                                Opaque (..), Reason (Ok),
                                                Reference, StateMachine (..),
                                                Symbolic, forAllCommands, notElem,
                                                genSym, opaque, prettyCommands,
                                                reference, runCommands, (.&&),
                                                (.//), (.<), (.==), (.>=))
import           Test.StateMachine.Types       (Commands (..))
import qualified Test.StateMachine.Types.Rank2 as Rank2
import           Text.Read                     (readEither)

import qualified Data.Functor.Classes
import           Debug.Trace                   (trace)

------------------------------------------------------------------------

type Port = Int

data Persistence = Fresh | Existing
  deriving (Show)

data ClientHandleRefs (r :: * -> *) = ClientHandleRefs
  { client_hin :: Reference (Opaque Handle) r
  , client_hout :: Reference (Opaque Handle) r
  } deriving (Show, Generic, Generic1, Rank2.Functor, Rank2.Foldable, Rank2.Traversable)

deriving instance ToExpr (ClientHandleRefs Concrete)

type ProcessHandleRef r = Reference (Opaque ProcessHandle) r

data Action (r :: * -> *)
  = SpawnNode Port Persistence
  | SpawnClient Port
  | KillNode (Port, ProcessHandleRef r)
  | Set (ClientHandleRefs r) Integer
  | Read (ClientHandleRefs r)
  | Incr (ClientHandleRefs r)
  | BreakConnection (Port, ProcessHandleRef r)
  | FixConnection   (Port, ProcessHandleRef r)
  deriving (Show, Generic1, Rank2.Functor, Rank2.Foldable, Rank2.Traversable)

data Response (r :: * -> *)
  = SpawnedNode (ProcessHandleRef r)
  | SpawnedClient (ClientHandleRefs r) (ProcessHandleRef r)
  | SpawnFailed Port
  | BrokeConnection
  | FixedConnection
  | Ack
  | Timeout
  | Value (Either String Integer)
  deriving (Show, Generic1, Rank2.Foldable)

data Model (r :: * -> *) = Model
  { nodes    :: [(Port, ProcessHandleRef r)]
  , client   :: Maybe (ClientHandleRefs r, ProcessHandleRef r)
  , started  :: Bool
  , value    :: Maybe Integer
  , isolated :: [(Port, ProcessHandleRef r)]
  }
  deriving (Show, Generic)

deriving instance ToExpr (Model Concrete)

initModel :: Model r
initModel = Model [] Nothing False Nothing []

transition :: Data.Functor.Classes.Show1 r => Model r -> Action r -> Response r -> Model r
transition Model {..} act resp = case (act, resp) of
  (SpawnNode port _, SpawnedNode ph) ->
    let newNodes = nodes ++ [(port, ph)]
     in if length newNodes == 3
           then Model { nodes = newNodes, started = True, .. }
           else Model { nodes = newNodes, .. }
  (SpawnNode {}, SpawnFailed _)    -> Model {..}
  (KillNode (port, _ph), Ack)      -> Model { nodes = filter ((/= port) . fst) nodes, .. }
  (Set _ i, Ack)                     -> Model { value = Just i, .. }
  (Read {}, Value _i)                 -> Model {..}
  (Incr {}, Ack)                      -> Model { value = succ <$> value, ..}
  (BreakConnection node, BrokeConnection) -> Model { isolated = node:isolated, .. }
  (FixConnection (port,_), FixedConnection)  -> Model { isolated = filter ((/= port) . fst) isolated, .. }
  (Read {}, Timeout)                  -> Model {..}
  (Set {}, Timeout)                -> Model {..}
  (Incr {}, Timeout)               -> Model {..}
  unaccounted                      -> trace (show unaccounted) $ error "transition"

-- TODO I don't think the precondition is being checked...
precondition :: Model Symbolic -> Action Symbolic -> Logic
precondition Model {..} act = case act of
  SpawnNode {}       -> length nodes .< 3
  KillNode  {}       -> length nodes .== 3
  Set _ i            -> length nodes .== 3 .&& i .>= 0
  Read _             -> length nodes .== 3 .&& Boolean (isJust value)
  Incr _             -> length nodes .== 3 .&& Boolean (isJust value)
  BreakConnection (port, _) -> length nodes .== 3 .&& port `notElem` map fst isolated
  FixConnection   {} -> length nodes .== 3 .&& Boolean (not (null isolated))

postcondition :: Model Concrete -> Action Concrete -> Response Concrete -> Logic
postcondition Model {..} act resp = case (act, resp) of
  (Read _, Value (Right i))      -> Just i .== value
  (Read _, Value (Left e))       -> Bot .// e
  (SpawnNode {}, SpawnedNode {}) -> Top
  (SpawnNode {}, SpawnFailed {}) -> Bot .// "SpawnFailed"
  (KillNode {}, Ack)             -> Top
  (Set {}, Ack)                  -> Top
  (Incr {}, Ack)                 -> Top
  (BreakConnection {}, BrokeConnection) -> Top
  (FixConnection {}, FixedConnection)   -> Top
  (Read _,    Timeout)           -> Boolean (not (null isolated)) .// "Read timeout"
  (Set {},  Timeout)             -> Boolean (not (null isolated)) .// "Set timeout"
  (Incr {}, Timeout)             -> Boolean (not (null isolated)) .// "Incr timeout"
  (_,            _)              -> Bot .// "postcondition"

command :: Handle -> ClientHandleRefs Concrete -> String -> IO (Maybe String)
command h chs@ClientHandleRefs{..} cmd = do
    eRes <- do
      hPutStrLn h cmd
      hPutStrLn (opaque client_hin) cmd
      mresp <- getResponse (opaque client_hout)
      case mresp of
        Nothing   -> pure Nothing
        Just resp ->
          if "system doesn't have a leader" `isInfixOf` resp
          then do
            hPutStrLn h "No leader, retrying..."
            threadDelay 100000 >> pure (Just Nothing)
          else do
            hPutStrLn h ("got response `" ++ resp ++ "'")
            pure (Just (Just resp))
    case eRes of
      Nothing -> pure Nothing
      -- Recurse if command successful
      Just Nothing -> command h chs cmd
      Just (Just resp) -> pure (Just resp)
  where
    getResponse :: Handle -> IO (Maybe String)
    getResponse hout = do
      mline <- timeout 1500000 (hGetLine hout)
      case mline of
        Nothing   -> return Nothing
        Just line
          | "New leader found" `isInfixOf` line -> getResponse hout
          | otherwise -> return (Just line)

semantics :: Handle -> Action Concrete -> IO (Response Concrete)
semantics h (SpawnNode port1 p) = do
  hPutStrLn h "Spawning node"
  removePathForcibly ("/tmp/raft-log-" ++ show port1 ++ ".txt")
  h' <- openFile ("/tmp/raft-log-" ++ show port1 ++ ".txt") WriteMode
  let port2, port3 :: Int
      (port2, port3) = case port1 of
        3000 -> (3001, 3002)
        3001 -> (3000, 3002)
        3002 -> (3000, 3001)
        _    -> error "semantics: invalid port1"
  let persistence Fresh    = "fresh"
      persistence Existing = "existing"
  (_, _, _, ph) <- createProcess_ "raft node"
    (proc "fiu-run" [ "-x", "stack", "exec", "raft-example", "node"
                    , persistence p
                    , "localhost:" ++ show port1
                    , "localhost:" ++ show port2
                    , "localhost:" ++ show port3
                    ])
      { std_out = UseHandle h'
      , std_err = UseHandle h'
      }
  threadDelay 1000000
  mec <- getProcessExitCode ph
  case mec of
    Nothing -> return (SpawnedNode (reference (Opaque ph)))
    Just ec -> do
      hPutStrLn h (show ec)
      return (SpawnFailed port1)

semantics h (SpawnClient cport) = do
  hPutStrLn h "Spawning client"
  (Just hin, Just hout, _, ph) <- createProcess_ "raft client"
    (proc "stack" [ "exec", "raft-example", "client" ])
     { std_out = CreatePipe
     , std_in  = CreatePipe
     , std_err = CreatePipe
     }

  threadDelay 1000000
  mec <- getProcessExitCode ph
  case mec of
    Just ec -> do
      hPutStrLn h (show ec)
      return (SpawnFailed cport)
    Nothing -> do
      threadDelay 100000
      hSetBuffering hin  NoBuffering
      hSetBuffering hout NoBuffering
      hPutStrLn hin "addNode localhost:3000"
      hPutStrLn hin "addNode localhost:3001"
      hPutStrLn hin "addNode localhost:3002"
      let refClient_hin = reference (Opaque hin)
          refClient_hout = reference (Opaque hout)
          clientHandleRefs = ClientHandleRefs refClient_hin refClient_hout
      return (SpawnedClient clientHandleRefs (reference (Opaque ph)))

semantics h (KillNode (_port, ph)) = do
  hPutStrLn h "Killing node"
  terminateProcess (opaque ph)
  return Ack
semantics h (Set chs i) = do
  mresp <- command h chs ("set x " ++ show i)
  case mresp of
    Nothing    -> return Timeout
    Just _resp -> return Ack
semantics h (Read chs) = do
  mresp <- command h chs "read"
  case mresp of
    Nothing   -> return Timeout
    Just resp -> do
      let parse = readEither
                . takeWhile isDigit
                . drop 1
                . snd
                . break (== ',')
      return (Value (bimap (++ (": " ++ resp)) id (parse resp)))
semantics h (Incr chs) = do
  mresp <- command h chs "incr x"
  case mresp of
    Nothing    -> return Timeout
    Just _resp -> return Ack
semantics h (BreakConnection (port, ph)) = do
  hPutStrLn h ("Break connection, port: " ++ show port)
  Just pid <- getPid (opaque ph)
  threadDelay 2000000
  callCommand ("fiu-ctrl -c \"enable name=posix/io/net/send\" " ++ show pid)
  callCommand ("fiu-ctrl -c \"enable name=posix/io/net/recv\" " ++ show pid)
  threadDelay 2000000
  return BrokeConnection
semantics h (FixConnection (port, ph)) = do
  hPutStrLn h ("Fix connection, port: " ++ show port)
  Just pid <- getPid (opaque ph)
  threadDelay 2000000
  callCommand ("fiu-ctrl -c \"disable name=posix/io/net/send\" " ++ show pid)
  callCommand ("fiu-ctrl -c \"disable name=posix/io/net/recv\" " ++ show pid)
  threadDelay 10000000
  return FixedConnection

generator :: Model Symbolic -> Gen (Action Symbolic)
generator Model {..}
  | length nodes < 3  =
      if started
        then flip SpawnNode Existing <$> elements ([3000..3002] \\ map fst nodes)
        else flip SpawnNode Fresh <$> elements ([3000..3002] \\ map fst nodes)
  | otherwise        =
      case client of
        Nothing -> SpawnClient <$> elements [3003..3010]
        Just (chs, _) ->
          case value of
            Nothing -> Set chs <$> arbitrary
            Just _  -> frequency $
              [ (1, Set chs <$> arbitrary)
              , (5, pure (Incr chs))
              , (3, pure (Read chs))
              , (1, KillNode <$> elements nodes)
              , (1, BreakConnection <$> elements nodes)
              ] ++ case isolated of
                     [] -> []
                     _ -> [(1, FixConnection <$> elements isolated)]

shrinker :: Action Symbolic -> [Action Symbolic]
shrinker (Set cph i) = [ Set cph i' | i' <- shrink i ]
shrinker _       = []

mock :: Model Symbolic -> Action Symbolic -> GenSym (Response Symbolic)
mock _m SpawnNode {}       = SpawnedNode <$> genSym
mock _m KillNode {}        = pure Ack
mock _m Set {}             = pure Ack
mock _m Read {}            = pure (Value (Right 0))
mock _m Incr {}            = pure Ack
mock _m BreakConnection {} = pure BrokeConnection
mock _m FixConnection {}   = pure FixedConnection

setup :: IO Handle
setup = do
  removePathForcibly "/tmp/raft-log.txt"
  h <- openFile "/tmp/raft-log.txt" WriteMode
  hSetBuffering h NoBuffering
  return h

sm :: Handle -> StateMachine Model Action IO Response
sm h = StateMachine initModel transition precondition postcondition
               Nothing generator Nothing shrinker (semantics h) mock

prop_sequential :: Property
prop_sequential = withMaxSuccess 10 $ noShrinking $
  forAllCommands (sm undefined) (Just 20) $ \cmds -> monadicIO $ do
    h <- liftIO setup
    let sm' = sm h
    (hist, model, res) <- runCommands sm' cmds
    prettyCommands sm' hist (res === Ok)
    liftIO (hClose h)
    liftIO (mapM_ (terminateProcess . opaque . snd) (nodes model))

------------------------------------------------------------------------

runMany :: Commands Action -> Handle -> Property
runMany cmds log = monadicIO $ do
  (hist, model, res) <- runCommands (sm log) cmds
  prettyCommands (sm log) hist (res === Ok)
  liftIO (mapM_ (terminateProcess . opaque . snd) (nodes model))

------------------------------------------------------------------------

-- swizzleClog :: Handle -> Property
-- swizzleClog = runMany cmds
--   where
--     cmds = Commands
--       [ Command (SpawnNode 3000 Fresh) (Set.fromList [ Var 0 ])
--       , Command (SpawnNode 3001 Fresh) (Set.fromList [ Var 1 ])
--       , Command (SpawnNode 3002 Fresh) (Set.fromList [ Var 2 ])
--       , Command (Set 0) Set.empty
--       , Command (BreakConnection ( 3000 , Reference (Symbolic  (Var 0)) )) Set.empty
--       , Command Incr Set.empty
--       , Command (BreakConnection ( 3001 , Reference (Symbolic  (Var 1)) )) Set.empty
--       , Command Incr Set.empty
--       , Command (BreakConnection ( 3002 , Reference (Symbolic  (Var 2)) )) Set.empty
--       , Command Incr Set.empty
--       , Command (FixConnection ( 3002 , Reference (Symbolic  (Var 2)) )) Set.empty
--       , Command Incr Set.empty
--       , Command (FixConnection ( 3001 , Reference (Symbolic  (Var 1)) )) Set.empty
--       , Command Incr Set.empty
--       , Command (FixConnection ( 3000 , Reference (Symbolic  (Var 0)) )) Set.empty
--       , Command Incr Set.empty
--       , Command Read Set.empty
--       ]
--
-- unit_swizzleClog :: IO ()
-- unit_swizzleClog = bracket setup hClose (verboseCheck . swizzleClog)

------------------------------------------------------------------------

exampleUnit :: Handle -> Property
exampleUnit = runMany cmds
  where
    cmds = Commands
      [ -- Commands go here...
      ]

unit_exampleUnit :: IO ()
unit_exampleUnit = bracket setup hClose (verboseCheck . exampleUnit)

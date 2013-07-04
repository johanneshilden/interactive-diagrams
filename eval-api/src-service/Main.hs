{-# LANGUAGE DeriveDataTypeable, RankNTypes, ImpredicativeTypes #-}
module Main where

import Control.Monad (when)
import Control.Concurrent (threadDelay)
import Data.Typeable (Typeable)
import Data.Default
import Data.ByteString (hGetContents, hPutStr)
import Data.Serialize (encode, decode, Serialize)
import Network (listenOn, connectTo, accept, socketPort, PortID(..), Socket(..))
import Network.Socket (close)
import System.Directory (doesFileExist)
import System.FilePath.Posix ((</>))
import System.IO (Handle, hClose)
import System.Posix.Files (removeLink)

import Eval.Worker
import Eval.EvalSettings

data ServCmd = WorkerReq
             | KillWorker (forall a. Worker a)
             deriving (Typeable)
  
sockFile :: FilePath
sockFile = "/idia/run/control.sock"

settings :: EvalSettings
settings = (def { limitSet = def { secontext = Nothing } })

main :: IO ()
main = do
  worker <- startEvalWorker "1" settings
  print =<< sendCompileFileRequest worker "/home/vagrant/test.hs"
  return ()

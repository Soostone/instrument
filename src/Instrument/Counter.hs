{-# LANGUAGE BangPatterns #-}

module Instrument.Counter
    ( Counter
    , newCounter
    , readCounter
    , resetCounter
    , add
    , increment
    ) where

-------------------------------------------------------------------------------
import           Control.Exception (mask_, onException)
import           Control.Monad
import           Data.IORef
-------------------------------------------------------------------------------



newtype Counter = Counter { unCounter :: IORef Int }

-------------------------------------------------------------------------------
newCounter :: IO Counter
newCounter = Counter `liftM` newIORef 0


-------------------------------------------------------------------------------
readCounter :: Counter -> IO Int
readCounter (Counter i) = readIORef i


-------------------------------------------------------------------------------
resetCounter :: Counter -> IO ()
resetCounter (Counter i) = atomicModifyIORef i f
    where f _ = (0, ())

-------------------------------------------------------------------------------
increment :: Counter -> IO ()
increment = add 1


-------------------------------------------------------------------------------
add :: Int -> Counter -> IO ()
add x c = atomicModifyIORef (unCounter c) f
    where
      f !i = (i + x, ())

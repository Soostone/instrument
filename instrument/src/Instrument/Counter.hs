{-# LANGUAGE BangPatterns #-}

module Instrument.Counter
  ( Counter,
    newCounter,
    readCounter,
    resetCounter,
    add,
    increment,
  )
where

-------------------------------------------------------------------------------
import Control.Monad
import Data.IORef

-------------------------------------------------------------------------------

newtype Counter = Counter {unCounter :: IORef Int}

-------------------------------------------------------------------------------
newCounter :: IO Counter
newCounter = Counter `liftM` newIORef 0

-------------------------------------------------------------------------------
readCounter :: Counter -> IO Int
readCounter (Counter i) = readIORef i

-------------------------------------------------------------------------------

-- | Reset the counter while reading it
resetCounter :: Counter -> IO Int
resetCounter (Counter i) = atomicModifyIORef i f
  where
    f i' = (0, i')

-------------------------------------------------------------------------------
increment :: Counter -> IO ()
increment = add 1

-------------------------------------------------------------------------------
add :: Int -> Counter -> IO ()
add x c = atomicModifyIORef (unCounter c) f
  where
    f !i = (i + x, ())

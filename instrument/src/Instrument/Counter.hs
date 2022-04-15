{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeApplications #-}

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
import Data.IORef
import qualified Data.Atomics.Counter as A
-------------------------------------------------------------------------------

data Counter = Counter {_atomicCounter :: A.AtomicCounter, _lastResetValue :: IORef Int}

-------------------------------------------------------------------------------
newCounter :: IO Counter
newCounter = Counter <$> A.newCounter 0 <*> newIORef 0

-------------------------------------------------------------------------------

-- |
readCounter :: Counter -> IO Integer
readCounter (Counter i lastReset) = fixRollover <$> readIORef lastReset <*> A.readCounter i

fixRollover :: Int -> Int -> Integer
fixRollover lastReset  current | current < lastReset =
  fromIntegral (maxBound @Int - lastReset) + fromIntegral (current - minBound @Int) + 1
fixRollover lastReset current = fromIntegral current - fromIntegral lastReset

-------------------------------------------------------------------------------

-- | Reset the counter while reading it
resetCounter :: Counter -> IO Integer
resetCounter (Counter i lastReset) = do
  ctrValue <- A.readCounter i
  oldLast <- atomicModifyIORef' lastReset $ \oldLast -> (ctrValue, oldLast)
  pure $ fixRollover oldLast ctrValue

-------------------------------------------------------------------------------
increment :: Counter -> IO ()
increment = add 1

-------------------------------------------------------------------------------
add :: Int -> Counter -> IO ()
add x (Counter i _) = A.incrCounter_ x i

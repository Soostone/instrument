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

-- | Reads current counter value
readCounter :: Counter -> IO Integer
readCounter (Counter i lastReset) = calculateDelta <$> readIORef lastReset <*> A.readCounter i

-- | Our counters are represented as Int (with machine word size) and increment
-- | only, with no possibility to reset. Since we report deltas, we need facility
-- | to reset counter: we do that by storing last reported value in IORef.
-- | When application will run for long-enough counters will inevitably overflow.
-- | In such case our delta would be negative – this does not make sense for increment only.
-- | To overcome this issue we apply heuristic: when current value of counter
-- | is lower last value the counter has been reset, rollover happened and we need to
-- | take it into account. Otherwise, we can simply subtract values.
calculateDelta :: Int -> Int -> Integer
calculateDelta lastReset current | current < lastReset =
  fromIntegral (maxBound @Int - lastReset) + fromIntegral (current - minBound @Int) + 1
calculateDelta lastReset current = fromIntegral current - fromIntegral lastReset

-------------------------------------------------------------------------------

-- | Reset the counter while reading it
resetCounter :: Counter -> IO Integer
resetCounter (Counter i lastReset) = do
  ctrValue <- A.readCounter i
  oldLast <- atomicModifyIORef' lastReset $ \oldLast -> (ctrValue, oldLast)
  pure $ calculateDelta oldLast ctrValue

-------------------------------------------------------------------------------
increment :: Counter -> IO ()
increment = add 1

-------------------------------------------------------------------------------
add :: Int -> Counter -> IO ()
add x (Counter i _) = A.incrCounter_ x i

-----------------------------------------------------------------------------
-- |
-- Module      :  Instrument.Sampler
-- Copyright   :  Soostone Inc
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  experimental
--
-- A container that can capture actual numeric values, efficiently and
-- concurrently buffering them in memory. We can impose a cap on how
-- many values are captured at a time.
----------------------------------------------------------------------------

module Instrument.Sampler
    ( Sampler (..)
    , new
    , sample
    , get
    , reset
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent.MVar
import           Control.Exception       (mask_, onException)
import           Control.Monad
import qualified Data.Vector.Mutable     as V
-------------------------------------------------------------------------------


-- |'BoundedChan' is an abstract data type representing a bounded channel.
data Buffer a = B {
       _size     :: Int
     , _contents :: V.IOVector a
     , _writePos :: MVar Int
     }

-- Versions of modifyMVar and withMVar that do not 'restore' the previous mask state when running
-- 'io', with added modification strictness.  The lack of 'restore' may make these perform better
-- than the normal version.  Moving strictness here makes using them more pleasant.
{-# INLINE modifyMVar_mask #-}
modifyMVar_mask :: MVar a -> (a -> IO (a,b)) -> IO b
modifyMVar_mask m io =
  mask_ $ do
    a <- takeMVar m
    (a',b) <- io a `onException` putMVar m a
    putMVar m $! a'
    return b

{-# INLINE modifyMVar_mask_ #-}
modifyMVar_mask_ :: MVar a -> (a -> IO a) -> IO ()
modifyMVar_mask_ m io =
  mask_ $ do
    a <- takeMVar m
    a' <- io a `onException` putMVar m a
    putMVar m $! a'


-------------------------------------------------------------------------------
newBuffer :: Int -> IO (Buffer a)
newBuffer lim = do
  pos  <- newMVar 0
  entries <- V.new lim
  return (B lim entries pos)


-- | Write an element to the channel. If the channel is full, nothing
-- will happen and the function will return immediately. We don't want
-- to disturb production code.
writeBuffer :: Buffer a -> a -> IO ()
writeBuffer (B size contents wposMV) x = modifyMVar_mask_ wposMV $
  \wpos ->
    case wpos >= size of
      True -> return wpos       -- buffer full, don't do anything
      False -> do
        V.write contents wpos x
        return (succ wpos)


-------------------------------------------------------------------------------
getBuffer :: Buffer a -> IO [a]
getBuffer (B _size contents pos) = do
  wpos <- modifyMVar_mask pos $ \ wpos -> return (wpos, wpos)
  forM [0.. (wpos - 1)] $ \ i -> (V.read contents i)



-------------------------------------------------------------------------------
resetBuffer :: Buffer a -> IO ()
resetBuffer (B _size _els pos) = modifyMVar_mask_ pos (const (return 0))




-- | An in-memory, bounded buffer for measurement samples.
newtype Sampler = S { unS :: Buffer Double }


-- | Create a new, empty sampler
new :: Int -> IO Sampler
new i = S `fmap` newBuffer i


-------------------------------------------------------------------------------
sample :: Double -> Sampler -> IO ()
sample v s = writeBuffer (unS s) v


-------------------------------------------------------------------------------
get :: Sampler -> IO [Double]
get (S buffer) = getBuffer buffer


-------------------------------------------------------------------------------
reset :: Sampler -> IO ()
reset (S buf) = resetBuffer buf

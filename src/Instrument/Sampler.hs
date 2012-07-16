module Instrument.Sampler
    ( Sampler (..)
    , new
    , sample
    , get
    , reset
    ) where


import           Control.Concurrent.MVar
import           Control.Exception       (mask_, onException)
import           Control.Monad
import           Data.Array              (Array, listArray, (!))
import           Data.IORef              (IORef, atomicModifyIORef, newIORef, readIORef)


-- |'BoundedChan' is an abstract data type representing a bounded channel.
data Buffer a = B {
       _size     :: Int
     , _contents :: Array Int (IORef a)
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


{-# INLINE withMVar_mask #-}
withMVar_mask :: MVar a -> (a -> IO b) -> IO b
withMVar_mask m io =
  mask_ $ do
    a <- takeMVar m
    b <- io a `onException` putMVar m a
    putMVar m a
    return b


-------------------------------------------------------------------------------
newBuffer :: a -> Int -> IO (Buffer a)
newBuffer a lim = do
  entls <- replicateM lim $ newIORef a
  pos  <- newMVar 0
  let entries = listArray (0, lim - 1) entls
  return (B lim entries pos)


-- |Write an element to the channel. If the channel is full, this routine will
-- block until it is able to write.  Blockers wait in a fair FIFO queue.
writeBuffer :: Buffer a -> a -> IO ()
writeBuffer (B size contents wposMV) x = modifyMVar_mask_ wposMV $
  \wpos ->
    case wpos >= size of
      True -> return wpos       -- buffer full, don't do anything
      False -> do
        atomicModifyIORef (contents ! wpos) (const (x, x))
        return (succ wpos)


-------------------------------------------------------------------------------
getBuffer :: Buffer a -> IO [a]
getBuffer (B size contents pos) = do
  wpos <- modifyMVar_mask pos $ \ wpos -> return (wpos, wpos)
  forM [0.. (wpos - 1)] $ \ i -> (readIORef (contents ! i))



-------------------------------------------------------------------------------
resetBuffer :: Buffer a -> IO ()
resetBuffer (B size els pos) = modifyMVar_mask_ pos (const (return 0))




-- | An in-memory, bounded buffer for measurement samples.
newtype Sampler = S { unS :: Buffer Double }


-- | Create a new, empty sampler
new :: Int -> IO Sampler
new i = S `fmap` newBuffer 0 i


-------------------------------------------------------------------------------
sample :: Double -> Sampler -> IO ()
sample v s = writeBuffer (unS s) v


-------------------------------------------------------------------------------
get :: Sampler -> IO [Double]
get (S buffer) = getBuffer buffer


-------------------------------------------------------------------------------
reset :: Sampler -> IO ()
reset (S buf) = resetBuffer buf

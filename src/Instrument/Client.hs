{-# LANGUAGE BangPatterns    #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}


module Instrument.Client
    ( Instrument
    , initInstrument
    , sample
    , time
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent         (ThreadId, forkIO, threadDelay)
import           Control.Exception          as E
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8      as B
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.IORef                 (IORef, atomicModifyIORef, newIORef,
                                             readIORef)
import qualified Data.Map                   as M
import           Data.Serialize
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import           Database.Redis             as R hiding (HostName (..), time)
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Measurement     as TM
import qualified Instrument.Sampler         as S
import           Instrument.Types
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
mkSP :: HostName -> T.Text -> [Double] -> IO SubmissionPacket
mkSP hostName nm vals = do
  ts <- TM.getTime
  return $ SP ts hostName nm vals


-- | Initialize an instrument
initInstrument :: ConnectInfo
               -- ^ Redis connection info
               -> IO Instrument
initInstrument conn = do
  p <- createInstrumentPool conn
  h        <- getHostName
  samplers <- newIORef M.empty
  tid      <- forkIO $ forever $ (submit h samplers p >> threadDelay 1000000)
  return $ I tid h samplers p


-- | Flush all samplers in Instrument
submit :: HostName -> IORef Samplers -> Connection -> IO ()
submit hn samplers redis = do
  ss <- getSamplers samplers
  mapM_ (flushSampler hn redis) ss


-- | Flush given sampler to remote service and flush in-memory queue
flushSampler :: HostName
             -> Connection
             -> (T.Text, S.Sampler)
             -> IO ()
flushSampler hostName r (name, sampler) = do
  vals <- S.get sampler
  case vals of
    [] -> return ()
    _ -> do
      S.reset sampler
      !sp <- mkSP hostName name vals
      runRedis r $ lpush rk [encode sp]
      return ()
  where
    rk = B.concat [B.pack "_sq_", T.encodeUtf8 name]


-- | Run a monadic action while measuring its runtime
time :: (MonadIO m) => T.Text -> Instrument -> m a -> m a
time name i act = do
  (!secs, !res) <- TM.time act
  liftIO $ sample name secs i
  return res


-- | Record given measurement
sample :: MonadIO m => T.Text -> Double -> Instrument -> m ()
sample name v i = liftIO $ S.sample v =<< getSampler name i


-- | Get or create a sampler under given name
getSampler        :: T.Text -> Instrument -> IO S.Sampler
getSampler name i = getRef name (samplers i)


-- | Get a list of current samplers present
getSamplers :: IORef Samplers -> IO [(T.Text, S.Sampler)]
getSamplers ss = M.toList `fmap` readIORef ss


-- | Lookup a 'Ref' by name in the given map.  If no 'Ref' exists
-- under the given name, create a new one, insert it into the map and
-- return it.
getRef
                   :: T.Text
                   -> IORef (M.Map T.Text S.Sampler)
                   -> IO S.Sampler
getRef name mapRef = do
    empty <- S.new 1000
    ref <- atomicModifyIORef mapRef $ \ m ->
        case M.lookup name m of
            Nothing  -> let m' = M.insert name empty m
                        in (m', empty)
            Just ref -> (m, ref)
    return ref
{-# INLINABLE getRef #-}


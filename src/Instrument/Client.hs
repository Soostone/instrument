{-# LANGUAGE BangPatterns #-}
module Instrument.Client
    ( Instrument
    , initInstrument
    , sampleI
    , timeI
    , incrementI
    , countI
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent     (forkIO)
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8  as B
import           Data.IORef             (IORef, atomicModifyIORef, newIORef,
                                         readIORef)
import qualified Data.Map               as M
import qualified Data.SafeCopy          as SC
import qualified Data.Text              as T
import           Database.Redis         as R hiding (HostName, time)
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Counter     as C
import qualified Instrument.Measurement as TM
import qualified Instrument.Sampler     as S
import           Instrument.Types
import           Instrument.Utils
-------------------------------------------------------------------------------



-- | Initialize an instrument for measurement and feeding data into the system.
--
-- The resulting opaque 'Instrument' is meant to be threaded around in
-- your application to be later used in conjunction with 'sample' and
-- 'time'.
initInstrument :: ConnectInfo
               -- ^ Redis connection info
               -> InstrumentConfig
               -- ^ Instrument configuration. Use "def" if you don't have specific needs
               -> IO Instrument
initInstrument conn cfg = do
    p <- createInstrumentPool conn
    h        <- getHostName
    smplrs <- newIORef M.empty
    ctrs <- newIORef M.empty
    void $ forkIO $ indefinitely' $ submitSamplers h smplrs p cfg
    void $ forkIO $ indefinitely' $ submitCounters h ctrs p cfg
    return $ I h smplrs ctrs p
  where
    indefinitely' = indefinitely "Client" (seconds 1)

-------------------------------------------------------------------------------
mkSampledSubmission :: HostName
                    -> MetricName
                    -> Dimensions
                    -> [Double]
                    -> IO SubmissionPacket
mkSampledSubmission host nm dims vals = do
  ts <- TM.getTime
  return $ SP ts nm (Samples vals) (addHostDimension host dims)


-------------------------------------------------------------------------------
addHostDimension :: HostName -> Dimensions -> Dimensions
addHostDimension host = M.insert hostDimension (DimensionValue (T.pack host))


-------------------------------------------------------------------------------
mkCounterSubmission :: HostName
                    -> MetricName
                    -> Dimensions
                    -> Int
                    -> IO SubmissionPacket
mkCounterSubmission hn m dims i = do
    ts <- TM.getTime
    return $ SP ts m (Counter i) (addHostDimension hn dims)


-- | Flush all samplers in Instrument
submitSamplers
  :: HostName
  -> IORef Samplers
  -> Connection
  -> InstrumentConfig
  -> IO ()
submitSamplers hn smplrs rds cfg = do
  ss <- getSamplers smplrs
  mapM_ (flushSampler hn rds cfg) ss


-- | Flush all samplers in Instrument
submitCounters
  :: HostName
  -> IORef Counters
  -> Connection
  -> InstrumentConfig
  -> IO ()
submitCounters hn cs r cfg = do
    ss <- M.toList `liftM` readIORef cs
    mapM_ (flushCounter hn r cfg) ss


-------------------------------------------------------------------------------
submitPacket :: (SC.SafeCopy a) => R.Connection -> MetricName -> Maybe Integer -> a -> IO ()
submitPacket r m mbound sp = void $ R.runRedis r push
    where rk = B.concat [B.pack "_sq_", B.pack (metricName m)]
          push = case mbound of
            Just n  -> lpushBounded rk [encodeCompress sp] n
            Nothing -> void $ R.lpush rk [encodeCompress sp]


-------------------------------------------------------------------------------
-- | Flush given counter to remote service and reset in-memory counter
-- back to 0.
flushCounter
  :: HostName
  -> Connection
  -> InstrumentConfig
  -> ((MetricName, Dimensions), C.Counter)
  -> IO ()
flushCounter hn r cfg ((m, dims), c) =
    C.resetCounter c >>=
    mkCounterSubmission hn m dims >>=
    submitPacket r m (redisQueueBound cfg)


-------------------------------------------------------------------------------
-- | Flush given sampler to remote service and flush in-memory queue
flushSampler
  :: HostName
  -> Connection
  -> InstrumentConfig
  -> ((MetricName, Dimensions), S.Sampler)
  -> IO ()
flushSampler host r cfg ((name, dims), sampler) = do
  vals <- S.get sampler
  case vals of
    [] -> return ()
    _ -> do
      S.reset sampler
      submitPacket r name (redisQueueBound cfg) =<< mkSampledSubmission host name dims vals


-------------------------------------------------------------------------------
-- | Increment a counter by one. Same as calling 'countI' with 1.
--
-- >>> incrementI \"uploadedFiles\" instr
incrementI :: (MonadIO m) => MetricName -> Dimensions -> Instrument -> m ()
incrementI m dims i = liftIO $ C.increment =<< getCounter m dims i


-------------------------------------------------------------------------------
-- | Increment a counter by n.
--
-- >>> countI \"uploadedFiles\" 1 instr
countI :: MonadIO m => MetricName -> Dimensions -> Int -> Instrument -> m ()
countI m dims n i = liftIO $ C.add n =<< getCounter m dims i


-- | Run a monadic action while measuring its runtime. Push the
-- measurement into the instrument system.
--
-- >>> timeI \"fileUploadTime\" instr $ uploadFile file
timeI :: (MonadIO m) => MetricName -> Dimensions -> Instrument -> m a -> m a
timeI name dims i act = do
  (!secs, !res) <- TM.time act
  liftIO $ sampleI nm dims secs i
  return res
  where
    nm = MetricName ("time." ++ metricName name)


-- | Record given measurement under the given label.
--
-- Instrument will automatically capture useful stats like min, max,
-- count, avg, stdev and percentiles within a single flush interval.
--
-- Say we check our upload queue size every minute and record
-- something like:
--
-- >>> sampleI \"uploadQueue\" 27 inst
sampleI :: MonadIO m => MetricName -> Dimensions -> Double -> Instrument -> m ()
sampleI name dims v i = liftIO $ S.sample v =<< getSampler name dims i


-------------------------------------------------------------------------------
getCounter :: MetricName -> Dimensions -> Instrument -> IO C.Counter
getCounter nm dims i = getRef C.newCounter (nm, dims) (counters i)


-- | Get or create a sampler under given name
getSampler :: MetricName -> Dimensions -> Instrument -> IO S.Sampler
getSampler name dims i = getRef (S.new 1000) (name, dims) (samplers i)


-- | Get a list of current samplers present
getSamplers :: IORef Samplers -> IO [((MetricName, Dimensions), S.Sampler)]
getSamplers ss = M.toList `fmap` readIORef ss


-- | Lookup a 'Ref' by name in the given map.  If no 'Ref' exists
-- under the given name, create a new one, insert it into the map and
-- return it.
getRef :: Ord k => IO b -> k -> IORef (M.Map k b) -> IO b
getRef f name mapRef = do
    empty <- f
    atomicModifyIORef mapRef $ \ m ->
        case M.lookup name m of
            Nothing  -> let m' = M.insert name empty m
                        in (m', empty)
            Just ref -> (m, ref)
{-# INLINABLE getRef #-}

-- | Bounded version of lpush which truncates *new* data first. This
-- effectively stops accepting data until the queue shrinks below the
-- bound.
lpushBounded :: B.ByteString -> [B.ByteString] -> Integer -> Redis ()
lpushBounded k vs mx = void $ multiExec $ do
  _ <- lpush k vs
  ltrim k (-mx) (-1)

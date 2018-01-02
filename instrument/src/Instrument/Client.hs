{-# LANGUAGE BangPatterns #-}
module Instrument.Client
    ( Instrument
    , initInstrument
    , sampleI
    , timeI
    , TM.time
    , submitTime
    , incrementI
    , countI
    , timerMetricName
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
    void $ forkIO $ indefinitely' $ submitSamplers smplrs p cfg
    void $ forkIO $ indefinitely' $ submitCounters ctrs p cfg
    return $ I h smplrs ctrs p
  where
    indefinitely' = indefinitely "Client" (seconds 1)

-------------------------------------------------------------------------------
mkSampledSubmission :: MetricName
                    -> Dimensions
                    -> [Double]
                    -> IO SubmissionPacket
mkSampledSubmission nm dims vals = do
  ts <- TM.getTime
  return $ SP ts nm (Samples vals) dims


-------------------------------------------------------------------------------
addHostDimension :: HostName -> Dimensions -> Dimensions
addHostDimension host = M.insert hostDimension (DimensionValue (T.pack host))


-------------------------------------------------------------------------------
mkCounterSubmission :: MetricName
                    -> Dimensions
                    -> Int
                    -> IO SubmissionPacket
mkCounterSubmission m dims i = do
    ts <- TM.getTime
    return $ SP ts m (Counter i) dims


-- | Flush all samplers in Instrument
submitSamplers
  :: IORef Samplers
  -> Connection
  -> InstrumentConfig
  -> IO ()
submitSamplers smplrs rds cfg = do
  ss <- getSamplers smplrs
  mapM_ (flushSampler rds cfg) ss


-- | Flush all samplers in Instrument
submitCounters
  :: IORef Counters
  -> Connection
  -> InstrumentConfig
  -> IO ()
submitCounters cs r cfg = do
    ss <- M.toList `liftM` readIORef cs
    mapM_ (flushCounter r cfg) ss


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
  :: Connection
  -> InstrumentConfig
  -> ((MetricName, Dimensions), C.Counter)
  -> IO ()
flushCounter r cfg ((m, dims), c) =
    C.resetCounter c >>=
    mkCounterSubmission m dims >>=
    submitPacket r m (redisQueueBound cfg)


-------------------------------------------------------------------------------
-- | Flush given sampler to remote service and flush in-memory queue
flushSampler
  :: Connection
  -> InstrumentConfig
  -> ((MetricName, Dimensions), S.Sampler)
  -> IO ()
flushSampler r cfg ((name, dims), sampler) = do
  vals <- S.get sampler
  case vals of
    [] -> return ()
    _ -> do
      S.reset sampler
      submitPacket r name (redisQueueBound cfg) =<< mkSampledSubmission name dims vals


-------------------------------------------------------------------------------
-- | Increment a counter by one. Same as calling 'countI' with 1.
--
-- >>> incrementI \"uploadedFiles\" instr
incrementI
  :: (MonadIO m)
  => MetricName
  -> HostDimensionPolicy
  -> Dimensions
  -> Instrument
  -> m ()
incrementI m hostDimPolicy rawDims i =
  liftIO $ C.increment =<< getCounter m dims i
  where
    dims = case hostDimPolicy of
      AddHostDimension -> addHostDimension (hostName i) rawDims
      DoNotAddHostDimension -> rawDims


-------------------------------------------------------------------------------
-- | Increment a counter by n.
--
-- >>> countI \"uploadedFiles\" 1 instr
countI
  :: MonadIO m
  => MetricName
  -> HostDimensionPolicy
  -> Dimensions
  -> Int
  -> Instrument
  -> m ()
countI m hostDimPolicy rawDims n i =
  liftIO $ C.add n =<< getCounter m dims i
  where
    dims = case hostDimPolicy of
      AddHostDimension -> addHostDimension (hostName i) rawDims
      DoNotAddHostDimension -> rawDims


-- | Run a monadic action while measuring its runtime. Push the
-- measurement into the instrument system.
--
-- >>> timeI \"fileUploadTime\" instr $ uploadFile file
timeI
  :: (MonadIO m)
  => MetricName
  -> HostDimensionPolicy
  -> Dimensions
  -> Instrument
  -> m a
  -> m a
timeI nm hostDimPolicy rawDims i act = do
  (!secs, !res) <- TM.time act
  submitTime nm hostDimPolicy rawDims secs i
  return res


-------------------------------------------------------------------------------
timerMetricName :: MetricName -> MetricName
timerMetricName name = MetricName ("time." ++ metricName name)

-------------------------------------------------------------------------------
-- | Sometimes dimensions are determined within a code block that
-- you're measuring. In that case, you can use 'time' to measure it
-- and when you're ready to submit, use 'submitTime'.
--
-- Also, you may be pulling time details from some external source
-- that you can't measure with 'timeI' yourself.
--
-- Note: for legacy purposes, metric name will have "time." prepended
-- to it.
submitTime
  :: (MonadIO m)
  => MetricName
  -> HostDimensionPolicy
  -> Dimensions
  -> Double
  -- ^ Time in seconds
  -> Instrument
  -> m ()
submitTime nameRaw hostDimPolicy rawDims secs i =
  liftIO $ sampleI nm hostDimPolicy rawDims secs i
  where
    nm = timerMetricName nameRaw


-------------------------------------------------------------------------------
-- | Record given measurement under the given label.
--
-- Instrument will automatically capture useful stats like min, max,
-- count, avg, stdev and percentiles within a single flush interval.
--
-- Say we check our upload queue size every minute and record
-- something like:
--
-- >>> sampleI \"uploadQueue\" 27 inst
sampleI
  :: MonadIO m
  => MetricName
  -> HostDimensionPolicy
  -> Dimensions
  -> Double
  -> Instrument
  -> m ()
sampleI name hostDimPolicy rawDims v i =
  liftIO $ S.sample v =<< getSampler name dims i
  where
    dims = case hostDimPolicy of
      AddHostDimension -> addHostDimension (hostName i) rawDims
      DoNotAddHostDimension -> rawDims


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

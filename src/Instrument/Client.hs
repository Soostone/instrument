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
import           Data.Serialize
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
mkSampledSubmission :: HostName -> String -> [Double] -> IO SubmissionPacket
mkSampledSubmission host nm vals = do
  ts <- TM.getTime
  return $ SP ts host nm (Samples vals)


-------------------------------------------------------------------------------
mkCounterSubmission :: HostName -> String -> Int -> IO SubmissionPacket
mkCounterSubmission hn m i = do
    ts <- TM.getTime
    return $ SP ts hn m (Counter i)


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
submitPacket :: (Serialize a, SC.SafeCopy a) => R.Connection -> String -> Maybe Integer -> a -> IO ()
submitPacket r m mbound sp = void $ R.runRedis r push
    where rk = B.concat [B.pack "_sq_", B.pack m]
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
  -> (String, C.Counter)
  -> IO ()
flushCounter hn r cfg (m, c) =
    C.resetCounter c >>=
    mkCounterSubmission hn m >>=
    submitPacket r m (redisQueueBound cfg)


-------------------------------------------------------------------------------
-- | Flush given sampler to remote service and flush in-memory queue
flushSampler
  :: HostName
  -> Connection
  -> InstrumentConfig
  -> (String, S.Sampler)
  -> IO ()
flushSampler host r cfg (name, sampler) = do
  vals <- S.get sampler
  case vals of
    [] -> return ()
    _ -> do
      S.reset sampler
      submitPacket r name (redisQueueBound cfg) =<< mkSampledSubmission host name vals


-------------------------------------------------------------------------------
-- | Increment a counter by one. Same as calling 'countI' with 1.
--
-- >>> incrementI \"uploadedFiles\" instr
incrementI :: (MonadIO m) => String -> Instrument -> m ()
incrementI m i = liftIO $ C.increment =<< getCounter m i


-------------------------------------------------------------------------------
-- | Increment a counter by n.
--
-- >>> countI \"uploadedFiles\" 1 instr
countI :: MonadIO m => String -> Int -> Instrument -> m ()
countI m n i = liftIO $ C.add n =<< getCounter m i


-- | Run a monadic action while measuring its runtime. Push the
-- measurement into the instrument system.
--
-- >>> timeI \"fileUploadTime\" instr $ uploadFile file
timeI :: (MonadIO m) => String -> Instrument -> m a -> m a
timeI name i act = do
  (!secs, !res) <- TM.time act
  liftIO $ sampleI nm secs i
  return res
  where
    nm = "time." ++ name


-- | Record given measurement under the given label.
--
-- Instrument will automatically capture useful stats like min, max,
-- count, avg, stdev and percentiles within a single flush interval.
--
-- Say we check our upload queue size every minute and record
-- something like:
--
-- >>> sampleI \"uploadQueue\" 27 inst
sampleI :: MonadIO m => String -> Double -> Instrument -> m ()
sampleI name v i = liftIO $ S.sample v =<< getSampler name i


-------------------------------------------------------------------------------
getCounter :: String -> Instrument -> IO C.Counter
getCounter nm i = getRef C.newCounter nm (counters i)


-- | Get or create a sampler under given name
getSampler        :: String -> Instrument -> IO S.Sampler
getSampler name i = getRef (S.new 1000) name (samplers i)


-- | Get a list of current samplers present
getSamplers :: IORef Samplers -> IO [(String, S.Sampler)]
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

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module Instrument.Worker
    ( initWorkerRedis
    , initWorkerCSV
    , work
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent         (ThreadId, forkIO, threadDelay)
import           Control.Error
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8      as B
import qualified Data.ByteString.Lazy.Char8 as LB
import           Data.CSV.Conduit
import           Data.Default
import qualified Data.Map                   as M
import           Data.Maybe
import           Data.Serialize
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import qualified Data.Text.IO               as T
import qualified Data.Vector.Unboxed        as V
import           Database.Redis             as R hiding (decode)
import qualified Statistics.Quantile        as Q
import           Statistics.Sample
import           System.IO
import           System.Posix
-------------------------------------------------------------------------------
import           Instrument.Client
import qualified Instrument.Measurement     as TM
import           Instrument.Types
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- | A redis backend that dumps results into Redis - not tested or
-- actively used.
initWorkerRedis
  :: ConnectInfo
  -- ^ Redis host, port
  -> Int
  -- ^ Aggregation period in seconds
  -> IO ()
initWorkerRedis conn n = do
  p <- createInstrumentPool conn
  forever $ work p n putAggregateRedis >> threadDelay (n * 1000000)


-------------------------------------------------------------------------------
-- | A CSV backend to store aggregation results in a CSV
initWorkerCSV
  :: ConnectInfo
  -> FilePath
  -- ^ Target file name
  -> Int
  -- ^ Aggregation period / flush interval in seconds
  -> IO ()
initWorkerCSV conn fp n = do
  !res <- fileExist fp
  !h <- openFile fp AppendMode
  hSetBuffering h LineBuffering
  unless res $ do
    T.hPutStrLn h $ rowToStr defCSVSettings . M.keys $ aggToCSV def
  p <- createInstrumentPool conn
  forever $ work p n (putAggregateCSV h) >> threadDelay (n * 1000000)


-------------------------------------------------------------------------------
-- | Extract statistics out of the given sample for this flush period
mkStats :: Sample -> Stats
mkStats s = Stats { smean = mean s
                  , ssum = V.sum s
                  , scount = V.length s
                  , smax = V.maximum s
                  , smin = V.minimum s
                  , srange = range s
                  , sstdev = stdDev s
                  , sskewness = skewness s
                  , skurtosis = kurtosis s
                  , squantiles = quantiles }
  where
    quantiles = M.fromList $ mkQ 100 99 : map (mkQ 100 . (* 10)) [1..9]
    mkQ mx i = (i, Q.weightedAvg i mx s)


-- | A function that does something with the aggregation results. Can
-- implement multiple backends simply using this.
type AggProcess = Aggregated -> Redis ()


-------------------------------------------------------------------------------
-- | Go over all pending stats buffers in redis.
work :: R.Connection -> Int -> AggProcess -> IO ()
work r n f = runRedis r $ do
    dbg $ "entered work block"
    res <- R.keys (B.pack "_sq_*")
    case res of
      Left _ -> return ()
      Right xs -> mapM_ (processSampler n f) xs


-------------------------------------------------------------------------------
processSampler
    :: Int
    -- ^ Flush interval - determines resolution
    -> AggProcess
    -- ^ What to do with aggregation results
    -> B.ByteString
    -- ^ Redis buffer for this metric
    -> Redis ()
processSampler n f k = do
  packets <- popLAll k
  case packets of
    [] -> return ()
    _ -> do
      let nm = spName . head $ packets
          sample = V.fromList . concatMap spVals $ packets
      t <- (fromIntegral . (* n) . (`div` n) . round) `liftM` liftIO TM.getTime
      let stats = mkStats sample
          agg = Aggregated t nm stats
      f agg
      return ()


-------------------------------------------------------------------------------
-- | Store aggregation results in Redis
putAggregateRedis :: AggProcess
putAggregateRedis agg = lpush rk [encode agg] >> return ()
  where rk = B.concat [B.pack "_is_", B.pack (aggName agg)]


-------------------------------------------------------------------------------
-- | Store aggregation results in a CSV file
putAggregateCSV :: Handle -> AggProcess
putAggregateCSV h agg = liftIO $ T.hPutStrLn h d
  where d = rowToStr defCSVSettings $ aggToCSV agg



-------------------------------------------------------------------------------
-- | Pop all keys in a redis List
popLAll :: Serialize a => B.ByteString -> Redis [a]
popLAll k = do
  res <- popLMany k 100
  case res of
    [] -> return res
    _ -> (res ++ ) `liftM` popLAll k


-------------------------------------------------------------------------------
-- | Pop up to N items from a queue. It will pop from left and preserve order.
popLMany :: Serialize a => B.ByteString -> Int -> Redis [a]
popLMany k n = do
    res <- replicateM n pop
    case sequence res of
      Left _ -> return []
      Right xs -> return $ mapMaybe conv $ catMaybes xs
    where
      pop = R.lpop k
      conv x =  hush $ decode x


-------------------------------------------------------------------------------
-- | Unwrap just enough to know if there was an exception. Expect that
-- there isn't one.
expect f = do
  res <- f
  case res of
    Left e -> unexpected e
    Right xs -> return xs


-------------------------------------------------------------------------------
-- | Raise the unexpected exception
unexpected r = error $ "Received an unexpected Left response from Redis. Reply: " ++ show r


-------------------------------------------------------------------------------
-- | Need to pull in a debugging library here.
dbg _ = return ()


-- ------------------------------------------------------------------------------
-- dbg :: (MonadIO m) => String -> m ()
-- dbg s = debug $ "Instrument.Worker: " ++ s

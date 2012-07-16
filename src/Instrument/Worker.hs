{-# LANGUAGE BangPatterns #-}

module Instrument.Worker
    ( initWorkerRedis
    , initWorkerCSV
    , work
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent     (ThreadId, forkIO, threadDelay)
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Aeson.TH
import qualified Data.ByteString.Char8  as B
import           Data.CSV.Conduit
import           Data.Default
import qualified Data.HashMap.Strict    as M
import qualified Data.Map               as Map
import           Data.Maybe
import           Data.Pool
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as T
import qualified Data.Text.IO           as T
import qualified Data.Vector.Unboxed    as V
import           Database.Redis.Redis   as R
import qualified Statistics.Quantile    as Q
import           Statistics.Sample
import           System.IO
import           System.Posix
-------------------------------------------------------------------------------
import           Dyna.Debug
import           Instrument.Client
import qualified Instrument.Measurement as TM
import           Instrument.Types
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
initWorkerRedis
  :: (String, String, Int)
  -- ^ Redis host, port, db number
  -> Int
  -- ^ Aggregation period in seconds
  -> IO ()
initWorkerRedis conn n = do
  p <- createInstrumentPool conn
  forever $ work p n putAggregateRedis >> threadDelay (n * 1000000)


-------------------------------------------------------------------------------
initWorkerCSV
  :: (String, String, Int)
  -> FilePath
  -> Int
  -> IO ()
initWorkerCSV conn fp n = do
  !res <- fileExist fp
  !h <- openFile fp AppendMode
  hSetBuffering h LineBuffering
  unless res $ do
    T.hPutStrLn h $ rowToStr defCSVSettings . Map.keys $ aggToCSV def
  p <- createInstrumentPool conn
  forever $ work p n (putAggregateCSV h) >> threadDelay (n * 1000000)


-------------------------------------------------------------------------------
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
    quantiles = M.fromList $ map mkQ [1..maxQ-1]
    maxQ = 10
    mkQ i = (i, Q.weightedAvg i maxQ s)



-- | A function that does something with the aggregation results. Can
-- implement multiple backends simply using this.
type AggProcess = Redis -> Aggregated -> IO ()


-------------------------------------------------------------------------------
-- | go over all pending stats buffers in redis; the right database
-- must have been selected prior
work :: Pool Redis -> Int -> AggProcess -> IO ()
work r n f = do
  dbg $ "entered work block"
  withResource r $ \ r -> do
    select r n
    res <- fromRMultiBulk =<< keys r "_sq_*"
    case res of
      Nothing -> undefined
      Just xs -> mapM_ (processSampler r f) $ catMaybes xs


-------------------------------------------------------------------------------
processSampler :: Redis -> AggProcess -> B.ByteString -> IO ()
processSampler r f k = do
  packets <- popLAll r k
  case packets of
    [] -> return ()
    _ -> do
      let nm = spName . head $ packets
          sample = V.fromList . concatMap spVals $ packets
      t <- (fromIntegral . (* 60) . (`div` 60) . round) `liftM` TM.getTime
      let stats = mkStats sample
          agg = Aggregated t nm stats
      f r agg
      return ()


-------------------------------------------------------------------------------
-- | Store aggregation results in Redis
putAggregateRedis :: AggProcess
putAggregateRedis r agg = lpush r rk (encode agg) >> return ()
  where rk = B.concat [B.pack "_s_", T.encodeUtf8 (aggName agg)]


-------------------------------------------------------------------------------
-- | Store aggregation results in a CSV file
putAggregateCSV :: Handle -> AggProcess
putAggregateCSV h _ agg = T.hPutStrLn h d
  where d = rowToStr defCSVSettings $ aggToCSV agg



-------------------------------------------------------------------------------
-- | Pop all keys in a redis List
popLAll r k = do
  res <- popLMany r k 100
  case res of
    [] -> return res
    _ -> (res ++ ) `liftM` popLAll r k


-------------------------------------------------------------------------------
-- | Pop up to N items from a queue. It will pop from left and preserve order.
popLMany :: FromJSON a => Redis -> B.ByteString -> Int -> IO [a]
popLMany r k n = do
  res <- run_multi r $ replicateM_ n . pop
  unwrap <- fromRMultiBulk res
  case unwrap of
    Nothing -> return []
    Just xs -> return $ mapMaybe conv $ catMaybes xs
  where
    pop r = lpop r k :: IO (Reply B.ByteString)
    conv x =  decode x


------------------------------------------------------------------------------
dbg :: (MonadIO m) => String -> m ()
dbg s = debug $ "Instrument.Worker: " ++ s

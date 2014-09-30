{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Instrument.Worker
    ( initWorkerCSV
    , initWorkerGraphite
    , work
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Error
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8  as B
import           Data.CSV.Conduit
import           Data.Default
import qualified Data.Map               as M
import           Data.Serialize
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as T
import qualified Data.Text.IO           as T
import qualified Data.Vector.Unboxed    as V
import           Database.Redis         as R hiding (decode)
import           Network
import qualified Statistics.Quantile    as Q
import           Statistics.Sample
import           System.IO
import           System.Posix
-------------------------------------------------------------------------------
import qualified Instrument.Measurement as TM
import           Instrument.Types
import           Instrument.Utils
-------------------------------------------------------------------------------



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
  initWorker conn n $ putAggregateCSV h


-------------------------------------------------------------------------------
-- | Initialize a Graphite backend
initWorkerGraphite
    :: ConnectInfo
    -- ^ Redis connection
    -> Int
    -- ^ Aggregation period / flush interval in seconds
    -> HostName
    -- ^ Graphite host
    -> Int
    -- ^ Graphite port
    -> IO b
initWorkerGraphite conn n server port = do
    h <- connectTo server (PortNumber $ fromIntegral port)
    hSetBuffering h LineBuffering
    initWorker conn n $ putAggregateGraphite h


-------------------------------------------------------------------------------
-- | Generic utility for making worker backends
initWorker conn n f = do
  p <- createInstrumentPool conn
  forever $ work p n f >> threadDelay (n * 1000000)



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
          byHost = collect packets spHostName id
          mkAgg xs =
              case (spPayload $ head xs) of
                Samples _ -> AggStats . mkStats . V.fromList .
                             concatMap (unSamples . spPayload) $
                             xs
                Counter _ -> AggCount . sum .
                             map (unCounter . spPayload) $
                             xs
      t <- (fromIntegral . (* n) . (`div` n) . round) `liftM` liftIO TM.getTime
      let agg = Aggregated t nm "all" $ mkAgg packets
          aggs = map mkHostAgg $ M.toList byHost
          mkHostAgg (hn, ps) = Aggregated t nm (T.encodeUtf8 $ T.concat ["hosts.", noDots $ T.pack hn]) $ mkAgg ps
      f agg
      mapM_ f aggs
      return ()



-- | A function that does something with the aggregation results. Can
-- implement multiple backends simply using this.
type AggProcess = Aggregated -> Redis ()



-------------------------------------------------------------------------------
-- | Store aggregation results in a CSV file
putAggregateCSV :: Handle -> AggProcess
putAggregateCSV h agg = liftIO $ T.hPutStrLn h d
  where d = rowToStr defCSVSettings $ aggToCSV agg


typePrefix AggStats{} = "samples"
typePrefix AggCount{} = "counts"


-------------------------------------------------------------------------------
-- | Push data into a Graphite database using the plaintext protocol
putAggregateGraphite :: Handle -> AggProcess
putAggregateGraphite h agg = liftIO $ mapM_ (T.hPutStrLn h . mkLine) ss
    where
      (ss, ts) = mkStatsFields agg
      mkLine (m, val) = T.concat
          [ "inst."
          , typePrefix (aggPayload agg), "."
          ,  T.pack (aggName agg), "."
          , m, "."
          , (T.decodeUtf8 $ aggGroup agg), " "
          , val, " "
          , ts ]


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
      conv x =  hush $ decodeCompress x


-------------------------------------------------------------------------------
-- | Need to pull in a debugging library here.
dbg _ = return ()


-- ------------------------------------------------------------------------------
-- dbg :: (MonadIO m) => String -> m ()
-- dbg s = debug $ "Instrument.Worker: " ++ s

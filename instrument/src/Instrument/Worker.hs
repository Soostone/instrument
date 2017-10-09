{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Instrument.Worker
    ( initWorkerCSV
    , initWorkerCSV'
    , initWorkerGraphite
    , initWorkerGraphite'
    , work
    , initWorker
    , AggProcess
    -- * Exported for testing
    , expandDims
    ) where

-------------------------------------------------------------------------------
import           Control.Error
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8  as B
import           Data.CSV.Conduit
import           Data.Default
import qualified Data.Map               as M
import           Data.Monoid
import qualified Data.SafeCopy          as SC
import           Data.Serialize
import qualified Data.Set               as Set
import qualified Data.Text              as T
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
initWorkerCSV conn fp n =
  initWorker "CSV Worker" conn n =<< initWorkerCSV' fp


-------------------------------------------------------------------------------
-- | Create an AggProcess that dumps to CSV. Use this to compose with
-- other AggProcesses
initWorkerCSV'
  :: FilePath
  -- ^ Target file name
  -- ^ Aggregation period / flush interval in seconds
  -> IO AggProcess
initWorkerCSV' fp = do
  !res <- fileExist fp
  !h <- openFile fp AppendMode
  hSetBuffering h LineBuffering
  unless res $
    T.hPutStrLn h $ rowToStr defCSVSettings . M.keys $ aggToCSV def
  return $ putAggregateCSV h


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
    -> IO ()
initWorkerGraphite conn n server port =
    initWorker "Graphite Worker" conn n =<< initWorkerGraphite' server port


-------------------------------------------------------------------------------
-- | Crete an AggProcess that dumps to graphite. Use this to compose
-- with other AggProcesses
initWorkerGraphite'
    :: HostName
    -- ^ Graphite host
    -> Int
    -- ^ Graphite port
    -> IO AggProcess
initWorkerGraphite' server port = do
    h <- connectTo server (PortNumber $ fromIntegral port)
    hSetBuffering h LineBuffering
    return $ putAggregateGraphite h


-------------------------------------------------------------------------------
-- | Generic utility for making worker backends. Will retry
-- indefinitely with exponential backoff.
initWorker :: String -> ConnectInfo -> Int -> AggProcess -> IO ()
initWorker wname conn n f = do
    p <- createInstrumentPool conn
    indefinitely' $ work p n f
  where
    indefinitely' = indefinitely wname (seconds n)



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
    dbg "entered work block"
    res <- R.keys (B.pack "_sq_*")
    case res of
      Left _   -> return ()
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
          byDims :: M.Map Dimensions [SubmissionPacket]
          byDims = collect packets spDimensions id
          mkAgg xs =
              case spPayload $ head xs of
                Samples _ -> AggStats . mkStats . V.fromList .
                             concatMap (unSamples . spPayload) $
                             xs
                Counter _ -> AggCount . sum .
                             map (unCounter . spPayload) $
                             xs
      t <- (fromIntegral . (* n) . (`div` n) . round) `liftM` liftIO TM.getTime
      let aggs = map mkDimsAgg $ M.toList $ expandDims $ byDims
          mkDimsAgg (dims, ps) = Aggregated t nm (mkAgg ps) dims
      mapM_ f aggs
      return ()


-------------------------------------------------------------------------------
-- | Take a map of packets by dimensions and *add* aggregations of the
-- existing dims that isolate each distinct dimension/dimensionvalue
-- pair + one more entry with an empty dimension set that aggregates
-- the whole thing.
-- worked example:
--
-- Given:
-- { {d1=>d1v1,d2=>d2v1} => p1
-- , {d1=>d1v1,d2=>d2v2} => p2
-- }
-- Produces:
-- { {d1=>d1v1,d2=>d2v1} => p1
-- , {d1=>d1v1,d2=>d2v2} => p2
-- , {d1=>d1v1} => p1 + p2
-- , {d2=>d2v1} => p1
-- , {d2=>d2v2} => p2
-- , {} => p1 + p2
-- }
expandDims
  :: forall packets. (Monoid packets, Eq packets)
  => M.Map Dimensions packets
  -> M.Map Dimensions packets
expandDims m =
  -- left-biased so technically if we have anything occupying the aggregated spots, leave them be
  m <> additions <> fullAggregation
  where
    distinctPairs :: Set.Set (DimensionName, DimensionValue)
    distinctPairs = Set.fromList (mconcat (M.toList <$> M.keys m))
    additions = foldMap mkIsolatedMap distinctPairs
    mkIsolatedMap :: (DimensionName, DimensionValue) -> M.Map Dimensions packets
    mkIsolatedMap dPair =
      let matches = snd <$> filter ((== dPair) . fst) mFlat
      in if matches == mempty
            then mempty
            else M.singleton (uncurry M.singleton dPair) (mconcat matches)
    mFlat :: [((DimensionName, DimensionValue), packets)]
    mFlat = [ ((dn, dv), packets)
            | (dimensionsMap, packets) <- M.toList m
            , (dn, dv) <- M.toList dimensionsMap]
    -- All packets across any combination of dimensions
    fullAggregation = M.singleton mempty (mconcat (M.elems m))


-- | A function that does something with the aggregation results. Can
-- implement multiple backends simply using this.
type AggProcess = Aggregated -> Redis ()



-------------------------------------------------------------------------------
-- | Store aggregation results in a CSV file
putAggregateCSV :: Handle -> AggProcess
putAggregateCSV h agg = liftIO $ T.hPutStrLn h d
  where d = rowToStr defCSVSettings $ aggToCSV agg


typePrefix :: AggPayload -> T.Text
typePrefix AggStats{} = "samples"
typePrefix AggCount{} = "counts"


-------------------------------------------------------------------------------
-- | Push data into a Graphite database using the plaintext protocol
putAggregateGraphite :: Handle -> AggProcess
putAggregateGraphite h agg = liftIO $ mapM_ (mapM_ (T.hPutStrLn h) . mkLines) ss
    where
      (ss, ts) = mkStatsFields agg
      -- Expand dimensions into one datum per dimension pair as the group
      mkLines (m, val) = for (M.toList (aggDimensions agg)) $ \(DimensionName dimName, DimensionValue dimVal) -> T.concat
          [ "inst."
          , typePrefix (aggPayload agg), "."
          ,  T.pack (metricName (aggName agg)), "."
          , m, "."
          , dimName, "."
          , dimVal, " "
          , val, " "
          , ts ]


-------------------------------------------------------------------------------
-- | Pop all keys in a redis List
popLAll :: (Serialize a, SC.SafeCopy a) => B.ByteString -> Redis [a]
popLAll k = do
  res <- popLMany k 100
  case res of
    [] -> return res
    _  -> (res ++ ) `liftM` popLAll k


-------------------------------------------------------------------------------
-- | Pop up to N items from a queue. It will pop from left and preserve order.
popLMany :: (Serialize a, SC.SafeCopy a) => B.ByteString -> Int -> Redis [a]
popLMany k n = do
    res <- replicateM n pop
    case sequence res of
      Left _   -> return []
      Right xs -> return $ mapMaybe conv $ catMaybes xs
    where
      pop = R.lpop k
      conv x =  hush $ decodeCompress x


-------------------------------------------------------------------------------
-- | Need to pull in a debugging library here.
dbg :: (Monad m) => String -> m ()
dbg _ = return ()


-- ------------------------------------------------------------------------------
-- dbg :: (MonadIO m) => String -> m ()
-- dbg s = debug $ "Instrument.Worker: " ++ s
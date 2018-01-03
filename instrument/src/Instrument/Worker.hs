{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Instrument.Worker
    ( initWorkerCSV
    , initWorkerCSV'
    , initWorkerGraphite
    , initWorkerGraphite'
    , work
    , initWorker
    , AggProcess(..)
    -- * Configuring agg processes
    , AggProcessConfig(..)
    , standardQuantiles
    , noQuantiles
    , quantileMap
    , defAggProcessConfig
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
import           Instrument.Client      (stripTimerPrefix, timerMetricName)
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
  -> AggProcessConfig
  -> IO ()
initWorkerCSV conn fp n cfg =
  initWorker "CSV Worker" conn n =<< initWorkerCSV' fp cfg


-------------------------------------------------------------------------------
-- | Create an AggProcess that dumps to CSV. Use this to compose with
-- other AggProcesses
initWorkerCSV'
  :: FilePath
  -- ^ Target file name
  -> AggProcessConfig
  -> IO AggProcess
initWorkerCSV' fp cfg = do
  !res <- fileExist fp
  !h <- openFile fp AppendMode
  hSetBuffering h LineBuffering
  unless res $
    T.hPutStrLn h $ rowToStr defCSVSettings . M.keys $ aggToCSV def
  return $ putAggregateCSV h cfg


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
    -> AggProcessConfig
    -> IO ()
initWorkerGraphite conn n server port cfg =
    initWorker "Graphite Worker" conn n =<< initWorkerGraphite' server port cfg


-------------------------------------------------------------------------------
-- | Crete an AggProcess that dumps to graphite. Use this to compose
-- with other AggProcesses
initWorkerGraphite'
    :: HostName
    -- ^ Graphite host
    -> Int
    -- ^ Graphite port
    -> AggProcessConfig
    -> IO AggProcess
initWorkerGraphite' server port cfg = do
    h <- connectTo server (PortNumber $ fromIntegral port)
    hSetBuffering h LineBuffering
    return $ putAggregateGraphite h cfg


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
mkStats :: Set.Set Quantile -> Sample -> Stats
mkStats qs s = Stats { smean = mean s
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
    quantiles = M.fromList (mkQ 100 . quantile <$> Set.toList qs)
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
processSampler n (AggProcess cfg f) k = do
  packets <- popLAll k
  case packets of
    [] -> return ()
    _ -> do
      let nm = spName . head $ packets
          -- with and without timer prefix
          qs = quantilesFn (stripTimerPrefix nm) <> quantilesFn (timerMetricName nm)
          byDims :: M.Map Dimensions [SubmissionPacket]
          byDims = collect packets spDimensions id
          mkAgg xs =
              case spPayload $ head xs of
                Samples _ -> AggStats . mkStats qs . V.fromList .
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
  where
    quantilesFn = metricQuantiles cfg


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
data AggProcess = AggProcess
  { apConfig :: AggProcessConfig
  , apProc   :: Aggregated -> Redis ()
  }


-------------------------------------------------------------------------------
-- | General configuration for agg processes. Defaulted with 'def' and 'defAggProcessConfig'
data AggProcessConfig = AggProcessConfig
  { metricQuantiles :: MetricName -> Set.Set Quantile
  -- ^ What quantiles should we calculate for any given metric, if
  -- any? We offer some common patterns for this in 'quantileMap',
  -- 'standardQuantiles', and 'noQuantiles'.
  }


-- | Uses 'standardQuantiles'.
defAggProcessConfig :: AggProcessConfig
defAggProcessConfig = AggProcessConfig standardQuantiles


instance Default AggProcessConfig where
  def = defAggProcessConfig


-- | Regardless of metric, produce no quantiles.
noQuantiles :: MetricName -> [Quantile]
noQuantiles = const mempty


-- | This is usually a good, comprehensive default. Produces quantiles
-- 10,20,30,40,50,60,70,80,90,99. *Note:* for some backends like
-- cloudwatch, each quantile produces an additional metric, so you
-- should probably consider using something more limited than this.
standardQuantiles :: MetricName -> Set.Set Quantile
standardQuantiles _ =
  Set.fromList [Q 10,Q 20,Q 30,Q 40,Q 50,Q 60,Q 70,Q 80,Q 90,Q 99]


-- | If you have a fixed set of metric names, this is often a
-- convenient way to express quantiles-per-metric.
quantileMap
  :: M.Map MetricName (Set.Set Quantile)
  -> Set.Set Quantile
  -- ^ What to return on miss
  -> (MetricName -> Set.Set Quantile)
quantileMap m qdef mn = fromMaybe qdef (M.lookup mn m)


-------------------------------------------------------------------------------
-- | Store aggregation results in a CSV file
putAggregateCSV :: Handle -> AggProcessConfig -> AggProcess
putAggregateCSV h cfg = AggProcess cfg $ \agg ->
  let d = rowToStr defCSVSettings $ aggToCSV agg
  in liftIO $ T.hPutStrLn h d


typePrefix :: AggPayload -> T.Text
typePrefix AggStats{} = "samples"
typePrefix AggCount{} = "counts"


-------------------------------------------------------------------------------
-- | Push data into a Graphite database using the plaintext protocol
putAggregateGraphite :: Handle -> AggProcessConfig -> AggProcess
putAggregateGraphite h cfg = AggProcess cfg $ \agg ->
    let (ss, ts) = mkStatsFields agg
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
    in liftIO $ mapM_ (mapM_ (T.hPutStrLn h) . mkLines) ss


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


-------------------------------------------------------------------------------
-- | Expand count aggregation to have the full columns
aggToCSV :: Aggregated -> M.Map T.Text T.Text
aggToCSV agg@Aggregated{..} = els <> defFields <> dimFields
  where
    els :: MapRow T.Text
    els = M.fromList $
            ("metric", T.pack (metricName aggName)) :
            ("timestamp", ts) :
            fields
    (fields, ts) = mkStatsFields agg
    defFields = M.fromList $ fst $ mkStatsFields $ agg { aggPayload =  (AggStats def) }
    dimFields = M.fromList [(k,v) | (DimensionName k, DimensionValue v) <- M.toList aggDimensions]


-------------------------------------------------------------------------------
-- | Get agg results into a form ready to be output
mkStatsFields :: Aggregated -> ([(T.Text, T.Text)], T.Text)
mkStatsFields Aggregated{..}  = (els, ts)
    where
      els =
        case aggPayload of
          AggStats Stats{..} ->
              [ ("mean", formatDecimal 6 False smean)
              , ("count", showT scount)
              , ("max", formatDecimal 6 False smax)
              , ("min", formatDecimal 6 False smin)
              , ("srange", formatDecimal 6 False srange)
              , ("stdDev", formatDecimal 6 False sstdev)
              , ("sum", formatDecimal 6 False ssum)
              , ("skewness", formatDecimal 6 False sskewness)
              , ("kurtosis", formatDecimal 6 False skurtosis)
              ] ++ (map mkQ $ M.toList squantiles)
          AggCount i ->
              [ ("count", showT i)]

      mkQ (k,v) = (T.concat ["percentile_", showT k], formatDecimal 6 False v)
      ts = formatInt aggTS

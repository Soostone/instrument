{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Instrument.CloudWatch
  ( CloudWatchICfg (..),
    mkDefCloudWatchICfg,
    QueueSize,
    queueSize,
    cloudWatchAggProcess,

    -- * Exported for testing
    slurpTBMQueue,
    splitNE,
  )
where

-------------------------------------------------------------------------------
import Control.Applicative as A
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMQueue
import qualified Control.Exception.Safe as EX
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Retry
import qualified Data.Foldable as FT
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import Data.Monoid as Monoid
import Data.Semigroup (sconcat)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Instrument
import Network.AWS
import qualified Network.AWS.CloudWatch as CW
import qualified Network.AWS.CloudWatch.Lens as CW

-------------------------------------------------------------------------------

-- | Construct with @preview queueSize@
newtype QueueSize = QueueSize Int deriving (Show, Eq, Ord)

-------------------------------------------------------------------------------

-- | Construct a queue size. Accepts value > 0
queueSize :: Prism' Int QueueSize
queueSize = prism' f t
  where
    t i
      | i > 0 = Just (QueueSize i)
      | otherwise = Nothing
    f (QueueSize i) = i

-------------------------------------------------------------------------------
data CloudWatchICfg = CloudWatchICfg
  { cwiNamespace :: Text,
    cwiQueueSize :: QueueSize,
    cwiEnv :: Env,
    -- | Note: you should probably limit the quantiles you publish with
    -- this backend. Every quantile you decide to publish for a metric
    -- has to be published as a *separate* metric because of the way
    -- cloudwatch works. So if you use something like
    -- 'standardQuantiles', you're going to see (and pay for) 11 metrics
    -- per metric you publish.
    cwiAggProcessConfig :: AggProcessConfig,
    -- | This hook will be executed on any unexpected exceptions so that you can
    -- log, for example.
    cwiOnError :: EX.SomeException -> IO (),
    -- | Delay this long on error in microseconds. This can be used to avoid log
    -- flooding
    cwiErrorDelay :: Maybe Int
  }

-- | Constructor for CloudWatchICfg. If or when new fields are added to the
-- record, they can be defaulted to avoid unnecessary breakage. Defaults to
-- 10,000 queue size, defAggProcessConfig, no-op on error and no delay on error.
mkDefCloudWatchICfg ::
  -- | Metric namespace
  Text ->
  -- | AWS Environment
  Env ->
  CloudWatchICfg
mkDefCloudWatchICfg ns env =
  CloudWatchICfg
    { cwiNamespace = ns,
      cwiQueueSize = QueueSize 10000,
      cwiEnv = env,
      cwiAggProcessConfig = defAggProcessConfig,
      cwiOnError = const (pure ()),
      cwiErrorDelay = Nothing
    }

-------------------------------------------------------------------------------
cloudWatchAggProcess ::
  CloudWatchICfg ->
  -- | Returns the function to push metrics and a
  -- finalizer. Finalizer blocks until workers are terminated.
  IO (AggProcess, IO ())
cloudWatchAggProcess cfg@CloudWatchICfg {..} = do
  q <- newTBMQueueIO (review queueSize cwiQueueSize)
  endSig <- newEmptyMVar
  worker <- async (startWorker cfg q)

  _ <- async $ do
    takeMVar endSig
    atomically $ closeTBMQueue q
    _ <- waitCatch worker
    putMVar endSig ()

  let writer agg = liftIO (atomically (void (tryWriteTBMQueue q agg)))

  let finalizer = putMVar endSig () >> takeMVar endSig
  return (AggProcess cwiAggProcessConfig writer, finalizer)

-------------------------------------------------------------------------------
startWorker :: CloudWatchICfg -> TBMQueue Aggregated -> IO ()
startWorker CloudWatchICfg {..} q = go
  where
    go = do
      maggs <- atomically (slurpTBMQueue q)
      case maggs of
        Just rawAggs -> do
          let datums = sconcat (toDatum A.<$> rawAggs)
          FT.forM_ (splitNE maxDatums datums) $ \datumPage -> do
            let pmd = CW.newPutMetricData cwiNamespace & CW.putMetricData_metricData .~ FT.toList datumPage
            res <- EX.tryAny (runResourceT (awsRetry (send cwiEnv pmd)))
            case res of
              Left e -> do
                void (EX.tryAny (cwiOnError e))
                maybe (pure ()) threadDelay cwiErrorDelay
              Right _ -> pure ()
          go
        Nothing -> return ()
    maxDatums = 20

-------------------------------------------------------------------------------
splitNE :: Int -> NonEmpty a -> NonEmpty (NonEmpty a)
splitNE n xs
  | n > 0 = NE.reverse (unsafeNE (unsafeNE <$> go [] (NE.toList xs)))
  | otherwise = xs :| []
  where
    go acc [] = acc
    go acc remaining =
      let (toAdd, remaining') = splitAt n remaining
       in go (toAdd : acc) remaining'
    unsafeNE (a : as) = a :| as
    unsafeNE _ = error "Impossible empty list passed to unsafeNE"

-------------------------------------------------------------------------------

-- | Expands the aggregated stats into datums. In most cases, this
-- will result in 1 datum. If the payload is an 'AggStats' and
-- contains quantiles, those will be emitted as individual metrics
-- with the quantile appended, e.g. metricName.p90
toDatum :: Aggregated -> NonEmpty CW.MetricDatum
toDatum a =
  baseDatum :| quantileDatums
  where
    baseDatum =
      mkDatum baseMetricName $ case aggPayload a of
        AggStats stats -> Right (toSS stats)
        AggCount n -> Left (fromIntegral n)
    mkDatum name dValOrStats =
      let base =
            CW.newMetricDatum (T.pack name)
              & CW.metricDatum_timestamp ?~ ts
              & CW.metricDatum_dimensions ?~ dims
       in -- Value and stats are mutually exclusive
          case dValOrStats of
            Left dVal -> base & CW.metricDatum_value ?~ dVal
            Right dStats -> base & CW.metricDatum_statisticValues ?~ dStats
    quantileDatums = uncurry mkQuantileDatum <$> quantiles
    mkQuantileDatum :: Int -> Double -> CW.MetricDatum
    mkQuantileDatum quantile val =
      mkDatum (baseMetricName Monoid.<> ".p" <> show quantile) (Left val)
    quantiles = case aggPayload a of
      AggStats stats -> M.toList (squantiles stats)
      AggCount _ -> []
    baseMetricName = (metricName (aggName a))
    ts = aggTS a ^. timeDouble
    dims = uncurry mkDim <$> take maxDimensions (M.toList (aggDimensions a))
    mkDim (DimensionName dn) (DimensionValue dv) = CW.newDimension dn dv
    maxDimensions = 10

-------------------------------------------------------------------------------
timeDouble :: Iso' Double UTCTime
timeDouble = iso toT fromT
  where
    toT :: Double -> UTCTime
    toT = posixSecondsToUTCTime . realToFrac
    fromT :: UTCTime -> Double
    fromT = realToFrac . utcTimeToPOSIXSeconds

-------------------------------------------------------------------------------
toSS :: Stats -> CW.StatisticSet
toSS Stats {..} = CW.newStatisticSet (fromIntegral scount) ssum smin smax

-------------------------------------------------------------------------------

-- | Nothing when closed and empty, retries when just empty
slurpTBMQueue :: TBMQueue a -> STM (Maybe (NonEmpty a))
slurpTBMQueue q = do
  mh <- readTBMQueue q
  case mh of
    Just h -> Just <$> go (h :| [])
    Nothing -> return Nothing
  where
    go acc = do
      ma <- tryReadTBMQueue q
      case ma of
        Just (Just a) -> go (NE.cons a acc)
        _ -> return acc

-------------------------------------------------------------------------------
awsRetry :: (MonadIO m, EX.MonadMask m) => m a -> m a
awsRetry = recovering policy [httpRetryH, networkRetryH] . const
  where
    policy = constantDelay 50000 <> limitRetries 5

-------------------------------------------------------------------------------

-- | Which exceptions should we retry?
httpRetryH :: Monad m => a -> EX.Handler m Bool
httpRetryH = const $ EX.Handler $ \(_ :: HttpException) -> return True

-------------------------------------------------------------------------------

-- | 'IOException's should be retried
networkRetryH :: Monad m => a -> EX.Handler m Bool
networkRetryH = const $ EX.Handler $ \(_ :: EX.IOException) -> return True

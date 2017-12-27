{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Instrument.CloudWatch
    ( CloudWatchICfg(..)
    , QueueSize
    , queueSize
    , cloudWatchAggProcess
    -- * Exported for testing
    , slurpTBMQueue
    , splitNE
    ) where

-------------------------------------------------------------------------------
import           Control.Applicative                  as A
import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBMQueue
import           Control.Exception                    (IOException)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Retry
import qualified Data.Foldable                        as FT
import           Data.List.NonEmpty                   (NonEmpty (..))
import qualified Data.List.NonEmpty                   as NE
import qualified Data.Map                             as M
import           Data.Monoid
import           Data.Text                            (Text)
import qualified Data.Text                            as T
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Instrument
import           Network.AWS
import           Network.AWS.CloudWatch.PutMetricData
import           Network.AWS.CloudWatch.Types
-------------------------------------------------------------------------------


-- | Construct with @preview queueSize@
newtype QueueSize = QueueSize Int deriving (Show, Eq, Ord)


-------------------------------------------------------------------------------
queueSize :: Prism' Int QueueSize
queueSize = prism' f t
  where t i
          | i > 0 = Just (QueueSize i)
          | otherwise = Nothing
        f (QueueSize i) = i


-------------------------------------------------------------------------------
data CloudWatchICfg = CloudWatchICfg
  { cwiNamespace        :: Text
  , cwiQueueSize        :: QueueSize
  , cwiEnv              :: Env
  , cwiAggProcessConfig :: AggProcessConfig
  -- ^ Note: you should probably limit the quantiles you publish with
  -- this backend. Every quantile you decide to publish for a metric
  -- has to be published as a *separate* metric because of the way
  -- cloudwatch works. So if you use something like
  -- 'standardQuantiles', you're going to see (and pay for) 11 metrics
  -- per metric you publish.
  }


-------------------------------------------------------------------------------
cloudWatchAggProcess
    :: CloudWatchICfg
    -> IO (AggProcess, IO ())
    -- ^ Returns the function to push metrics and a
    -- finalizer. Finalizer blocks until workers are terminated.
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
  where go = do
          maggs <- atomically (slurpTBMQueue q)
          case maggs of
            Just rawAggs -> do
              FT.forM_ (splitNE maxDatums rawAggs) $ \aggs -> do
                let pmd = putMetricData cwiNamespace & pmdMetricData .~ FT.toList (toDatum A.<$> aggs)
                void (runResourceT (awsRetry (runAWS cwiEnv (send pmd))))
              go
            Nothing -> return ()
        maxDatums = 20


-------------------------------------------------------------------------------
splitNE :: Int -> NonEmpty a -> NonEmpty (NonEmpty a)
splitNE n xs
        | n > 0 = NE.reverse (unsafeNE (unsafeNE <$> go [] (NE.toList xs)))
        | otherwise = xs :| []
  where go acc [] = acc
        go acc remaining = let (toAdd, remaining') = splitAt n remaining
                           in go (toAdd:acc) remaining'
        unsafeNE (a:as) = a :| as
        unsafeNE _      = error "Impossible empty list passed to unsafeNE"


-------------------------------------------------------------------------------
--TODO: publish quantiles
toDatum :: Aggregated -> MetricDatum
toDatum a = md & mdTimestamp .~ Just ts
                              & mdStatisticValues .~ ss
                              & mdValue .~ val
                              & mdDimensions .~ dims
  where md = metricDatum (T.pack (metricName (aggName a)))
        ts = aggTS a ^. timeDouble
        ss = case aggPayload a of
               AggStats stats -> Just (toSS stats)
               _              -> Nothing
        val = case aggPayload a of
                AggCount n -> Just (fromIntegral n)
                _          -> Nothing
        dims = uncurry mkDim <$> take maxDimensions (M.toList (aggDimensions a))
        mkDim (DimensionName dn) (DimensionValue dv) = dimension dn dv
        -- | <http://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_limits.html>
        maxDimensions = 10


-------------------------------------------------------------------------------
timeDouble :: Iso' Double UTCTime
timeDouble = iso toT fromT
  where toT :: Double -> UTCTime
        toT = posixSecondsToUTCTime . realToFrac
        fromT :: UTCTime -> Double
        fromT = realToFrac . utcTimeToPOSIXSeconds


-------------------------------------------------------------------------------
toSS :: Stats -> StatisticSet
toSS Stats {..} = statisticSet (fromIntegral scount) ssum smin smax


-------------------------------------------------------------------------------
-- | Nothing when closed and empty, retries when just empty
slurpTBMQueue :: TBMQueue a -> STM (Maybe (NonEmpty a))
slurpTBMQueue q = do
  mh <- readTBMQueue q
  case mh of
    Just h  -> Just <$> go (h :| [])
    Nothing -> return Nothing
  where go acc = do ma <- tryReadTBMQueue q
                    case ma of
                      Just (Just a) -> go (NE.cons a acc)
                      _             -> return acc


-------------------------------------------------------------------------------
awsRetry :: (MonadIO m, MonadMask m) => m a -> m a
awsRetry = recovering policy [httpRetryH, networkRetryH] . const
  where policy = constantDelay 50000 <> limitRetries 5


-------------------------------------------------------------------------------
-- | Which exceptions should we retry?
httpRetryH :: Monad m => a -> Handler m Bool
httpRetryH = const $ Handler $ \ (_ :: HttpException) -> return True


-------------------------------------------------------------------------------
-- | 'IOException's should be retried
networkRetryH :: Monad m => a -> Handler m Bool
networkRetryH = const $ Handler $ \ (_ :: IOException) -> return True

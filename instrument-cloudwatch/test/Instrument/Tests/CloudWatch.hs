{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Instrument.Tests.CloudWatch
  ( tests,
  )
where

-------------------------------------------------------------------------------

import qualified Amazonka
import qualified Amazonka.CloudWatch as CW
import qualified Amazonka.CloudWatch.GetMetricStatistics as CW
import qualified Amazonka.CloudWatch.Types.Datapoint as CW
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMQueue
import Control.Lens
import Control.Monad
import Data.Default
import qualified Data.Foldable as FT
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import Data.Maybe (catMaybes)
import Data.Semigroup
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Database.Redis
-------------------------------------------------------------------------------
import Instrument
import Instrument.CloudWatch
import qualified System.IO as IO
import Test.QuickCheck
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

-------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Instrument.CloudWatch"
    [ slurpTBMQueueTests,
      splitNEWithSizeTests,
      cloudWatchTests
    ]

-------------------------------------------------------------------------------
slurpTBMQueueTests :: TestTree
slurpTBMQueueTests =
  testGroup
    "slurpTBMQueue"
    [ testCase "returns Nothing immediately on a closed, empty queue" $ do
        q <- mkQueue 2
        atomically (closeTBMQueue q)
        res <- atomically (slurpTBMQueue q)
        res @?= Nothing,
      testCase "Returns the rest of the queue when closed" $ do
        q <- mkQueue 2
        atomically (writeTBMQueue q "one")
        atomically (closeTBMQueue q)
        res <- atomically (slurpTBMQueue q)
        res @?= Just ("one" :| []),
      testCase "Returns the whole queue when its open" $ do
        q <- mkQueue 2
        atomically (writeTBMQueue q "one")
        res <- atomically (slurpTBMQueue q)
        res @?= Just ("one" :| [])
    ]

cloudWatchTests :: TestTree
cloudWatchTests =
  testGroup
    "CloudWatch"
    [ withRedisCleanup $ testCase "works with bounded size/count limitation" . cloudwatch_size_limitation
    ]

cloudwatch_size_limitation :: IO Connection -> IO ()
cloudwatch_size_limitation mkConn = do
  conn <- mkConn
  instr <- initInstrument redisCI icfg
  awsEnv <- initAWSEnv

  forM_ (take 50 $ cycle [(1 :: Integer) .. 10]) $ \n ->
    let newDims = M.insert (DimensionName "test_id") (DimensionValue ("test" <> T.pack (show n))) dims
     in sampleI key DoNotAddHostDimension newDims 1 instr

  threadDelay 1000000

  let cfg =
        (mkDefCloudWatchICfg cwNamespace awsEnv)
          { cwiAggProcessConfig = AggProcessConfig noQuantiles,
            cwiMaxDatums = Just 10
          }
  (aggProcess, _finalize) <- cloudWatchAggProcess cfg

  startTime <- getCurrentTime
  let worker = work conn 1 aggProcess
  withAsync worker $ \_ -> do
    threadDelay 2000000
    -- pull metrics from CloudWatch for 'test10' dimension, which should have 5 samples
    totalSampleCount <- getMetrics awsEnv startTime

    -- for some weird reason, localstack CW returns double the sample count
    totalSampleCount @?= 10
  where
    icfg :: InstrumentConfig
    icfg = def {redisQueueBound = Nothing}

    cwNamespace = "test-namespace"

    key :: MetricName
    key = MetricName "instrument-test"

    dims :: Dimensions
    dims = M.fromList [(DimensionName "server", DimensionValue "app1")]

    dim = CW.newDimension "test_id" "test10"

    getMetrics awsEnv startTime = do
      now <- getCurrentTime
      let req =
            CW.newGetMetricStatistics cwNamespace "instrument-test" startTime now 60
              & CW.getMetricStatistics_statistics ?~ CW.Statistic_SampleCount :| []
              & CW.getMetricStatistics_dimensions ?~ [dim]

          getTotalSampleCount res =
            sum . catMaybes $
              res ^.. CW.getMetricStatisticsResponse_datapoints . _Just . folded . CW.datapoint_sampleCount

      res <- Amazonka.runResourceT (Amazonka.send awsEnv req)
      pure (getTotalSampleCount res)

-------------------------------------------------------------------------------
mkQueue :: Int -> IO (TBMQueue String)
mkQueue = newTBMQueueIO

-------------------------------------------------------------------------------
newtype DataWithSize = DataWithSize {_dataWithSize :: Int}
  deriving newtype (Show, Eq, Num, Arbitrary)

instance HasSize DataWithSize where
  calculateSize (DataWithSize a) = a

splitNEWithSizeTests :: TestTree
splitNEWithSizeTests =
  testGroup
    "splitNEWithSize"
    [ testProperty "0 or negative size" $ \(NonEmpty nel) n ->
        n
          <= 0
          ==> let ne = NE.fromList nel :: NonEmpty DataWithSize
               in splitNEWithSize (MaxSize n) (MaxCount 10000) ne === ne :| [],
      testCase "positive size, no items exceed length" $ do
        let ne = NE.fromList $ take 1000 (DataWithSize <$> cycle [1 .. 10])
            -- some random max size that is bigger than any single item
            maxChunkSize = MaxSize 123
            maxCount = MaxCount 10000
            res = splitNEWithSize maxChunkSize maxCount ne

        forM_ res $ \chunk ->
          assertBool "chunk's total size must not be bigger than the maxChunkSize" (sum (fmap calculateSize chunk) <= unMaxSize maxChunkSize),
      testCase "positive size, have the correct set of chunks" $ do
        let d = DataWithSize 3
            ne = NE.fromList $ replicate 100 d
            maxChunkSize = MaxSize 10
            maxCount = MaxCount 10000
            res = splitNEWithSize maxChunkSize maxCount ne

        -- total size is 300
        -- each chunk would get 3 d's (with a total size of 9 for each chunk)
        -- so we should observe 33 full chunks and a single one-item chunk
        res @?= NE.fromList (fmap NE.fromList (replicate 33 (replicate 3 d) <> [replicate 1 d])),
      testProperty "positive size, loses no items and preserves order" $ \(NonEmpty nel) (Positive n) ->
        let ne = NE.fromList nel :: NonEmpty DataWithSize
            maxCount = MaxCount 10000
            res = splitNEWithSize (MaxSize n) maxCount ne
         in sconcat res === ne,
      testProperty "0 or negative count" $ \(NonEmpty nel) n ->
        n
          <= 0
          ==> let ne = NE.fromList nel :: NonEmpty DataWithSize
               in splitNEWithSize (MaxSize 10000) (MaxCount n) ne === ne :| [],
      testProperty "positive count, no items exceed maxCount" $ \(Positive n) ->
        let ne = NE.fromList $ take 1000 (DataWithSize <$> cycle [1 .. 10])
            -- some random max size that is bigger than any single item
            maxChunkSize = MaxSize 100000
            maxCount = MaxCount n
            res = splitNEWithSize maxChunkSize maxCount ne
         in FT.all ((<= n) . NE.length) res,
      testCase "positive count, have the correct set of chunks" $ do
        let d = DataWithSize 3
            ne = NE.fromList $ replicate 101 d
            maxChunkSize = MaxSize 100000
            maxCount = MaxCount 10
            res = splitNEWithSize maxChunkSize maxCount ne

        -- total size is 300
        -- each chunk would get 3 d's (with a total size of 9 for each chunk)
        -- so we should observe 33 full chunks and a single one-item chunk
        res @?= NE.fromList (fmap NE.fromList (replicate 10 (replicate 10 d) <> [replicate 1 d])),
      testProperty "positive count, loses no items and preserves order" $ \(NonEmpty nel) (Positive n) ->
        let ne = NE.fromList nel :: NonEmpty DataWithSize
            maxChunkSize = MaxSize 100000
            maxCount = MaxCount n
            res = splitNEWithSize maxChunkSize maxCount ne
         in sconcat res === ne,
      testProperty "no chunk exceeds maxChunkSize or maxCount" $ \(NonEmpty nel) (Positive mSize) (Positive mCount) ->
        (mSize > maximum (fmap calculateSize nel)) ==>
          let ne = NE.fromList nel :: NonEmpty DataWithSize
              maxChunkSize = MaxSize mSize
              maxCount = MaxCount mCount
              res = splitNEWithSize maxChunkSize maxCount ne
           in FT.all (\chunk -> (NE.length chunk <= mCount) && sum (fmap calculateSize chunk) <= mSize) res
    ]

-------------------------------------------------------------------------------
withRedisCleanup :: (IO Connection -> TestTree) -> TestTree
withRedisCleanup = withResource rconnect cleanup
  where
    rconnect = do
      conn <- connect redisCI
      void . runRedis conn $ do
        ks <- either mempty id <$> smembers packetsKey
        del (packetsKey : ks)
      pure conn
    cleanup conn = void $
      runRedis conn $ do
        ks <- either mempty id <$> smembers packetsKey
        _ <- del (packetsKey : ks)
        quit

-------------------------------------------------------------------------------
redisCI :: ConnectInfo
redisCI = defaultConnectInfo {connectPort = PortNumber 6380}

initAWSEnv :: IO Amazonka.Env
initAWSEnv = do
  logger <- Amazonka.newLogger Amazonka.Debug IO.stdout
  env <- Amazonka.newEnv Amazonka.discover <&> \e -> (foldr Amazonka.configureService e overrides) {Amazonka.logger = logger}
  pure (Amazonka.globalTimeout 300 env)
  where
    overrides = [Amazonka.setEndpoint False "localhost" 4566 CW.defaultService]

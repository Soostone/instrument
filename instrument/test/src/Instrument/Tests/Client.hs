{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Instrument.Tests.Client
  ( tests,
  )
where

-------------------------------------------------------------------------------
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception.Safe (Exception, throwM, tryAny)
import Control.Monad
import Control.Monad.IO.Class
import Data.Default
import Data.List (find)
import qualified Data.Map as M
import Data.Monoid as Monoid
import Database.Redis
-------------------------------------------------------------------------------
import Instrument.Client
import Instrument.Tests.Arbitrary ()
import Instrument.Types
import Instrument.Worker
import System.Timeout
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

-------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Instrument.Client"
    [ withRedisCleanup $ testCase "queue bounding works" . queue_bounding_test,
      withRedisCleanup $ testCase "multiple keys eventually get flushed" . multi_key_test,
      withRedisCleanup $ testCaseSteps "also times exceptions" . time_test,
      timerMetricNameTests
    ]

-------------------------------------------------------------------------------
queue_bounding_test :: IO Connection -> IO ()
queue_bounding_test mkConn = do
  conn <- mkConn
  instr <- initInstrument redisCI icfg
  agg <- newEmptyMVar
  replicateM_ 2 (sampleI key DoNotAddHostDimension dims 1 instr >> sleepFlush)
  -- redis queue slots now full of the above aggregate
  -- bounds will drop these
  sampleI key DoNotAddHostDimension dims 100 instr
  sleepFlush
  let worker = work conn 1 (AggProcess defAggProcessConfig (liftIO . putMVar agg))
  withAsync worker $ \_ -> do
    Aggregated {aggPayload = AggStats Stats {..}} <- takeMVar agg
    assertEqual
      "throws away newer data exceeding bounds"
      (2, 1, 1, 2)
      (scount, smin, smax, ssum)

-------------------------------------------------------------------------------
sleepFlush :: IO ()
sleepFlush = threadDelay 1100000

data TimeException
  = TimeException
  deriving (Show)

instance Exception TimeException

-------------------------------------------------------------------------------
time_test :: IO Connection -> (String -> IO a) -> IO ()
time_test mkConn step = do
  conn <- mkConn
  instr <- initInstrument redisCI icfg
  aggsRef <- newTVarIO []

  let toMetric resE =
        case resE of
          Left _ -> ("instrument-test-timeex-error", DoNotAddHostDimension, Monoid.mempty)
          Right _ -> ("instrument-test-timeex", DoNotAddHostDimension, Monoid.mempty)

  void . tryAny . timeExI toMetric instr $ throwM TimeException

  timeExI toMetric instr $ pure ()

  void . tryAny
    . timeI
      "instrument-test-time-error"
      DoNotAddHostDimension
      Monoid.mempty
      instr
    $ throwM TimeException

  timeI
    "instrument-test-time"
    DoNotAddHostDimension
    Monoid.mempty
    instr
    $ pure ()

  sleepFlush

  let collectAggs = work conn 1 (AggProcess defAggProcessConfig (\agg -> liftIO (atomically (modifyTVar' aggsRef (agg :)))))

  withAsync collectAggs $ \worker -> do
    maggs <- timeout 2000000 $
      atomically $ do
        aggs <- readTVar aggsRef
        check (length aggs == 3)
        return aggs
    cancel worker
    case maggs of
      Nothing -> assertFailure "Waited 2 seconds and never received any aggs!"
      Just aggs -> do
        let getCount payload =
              case payload of
                (AggStats stats) -> scount stats
                (AggCount n) -> n

            countMatches name n = do
              void $ step name
              case filter ((== MetricName ("time." <> name)) . aggName) aggs of
                [agg] -> getCount (aggPayload agg) @?= n
                _ -> assertFailure (name <> "has multiple aggregations")

        countMatches "instrument-test-timeex" 1
        countMatches "instrument-test-timeex-error" 1
        countMatches "instrument-test-time" 1

        void $ step "instrument-test-time-error"
        length (filter ((== MetricName "time.instrument-test-time-error") . aggName) aggs) @?= 0

-------------------------------------------------------------------------------
multi_key_test :: IO Connection -> IO ()
multi_key_test mkConn = do
  conn <- mkConn
  instr <- initInstrument redisCI icfg
  aggsRef <- newTVarIO []
  sampleI "instrument-test1" DoNotAddHostDimension Monoid.mempty 1 instr
  sampleI "instrument-test2" DoNotAddHostDimension mempty 2 instr
  sleepFlush
  let collectAggs = work conn 1 (AggProcess defAggProcessConfig (\agg -> liftIO (atomically (modifyTVar' aggsRef (agg :)))))
  withAsync collectAggs $ \worker -> do
    maggs <- timeout 2000000 $
      atomically $ do
        aggs <- readTVar aggsRef
        check (length aggs >= 2)
        return aggs
    cancel worker
    case maggs of
      Nothing -> assertFailure "Waited 2 seconds and never received any aggs!"
      Just aggs -> do
        length aggs @?= 2
        let findAgg n expectedMean = do
              let magg = find ((== MetricName n) . aggName) aggs
              case magg of
                Nothing -> assertFailure ("Expected to find agg with name " <> n <> " but could not")
                Just (Aggregated {aggPayload = AggStats (Stats {smean = actualMean})}) -> actualMean @?= expectedMean
                Just _ -> assertFailure ("Expected agg with name " <> n <> " to contain Stats but it did not.")
        findAgg "instrument-test1" 1.0
        findAgg "instrument-test2" 2.0

-------------------------------------------------------------------------------
timerMetricNameTests :: TestTree
timerMetricNameTests =
  testGroup
    "timerMetricName"
    [ testProperty "is idempotent" $ \mn ->
        let r1 = timerMetricName mn
            r2 = timerMetricName r1
         in r1 === r2,
      testProperty "is idempotent for timers" $ \(MetricName mnBase) ->
        let mn = MetricName (timerMetricNamePrefix <> mnBase)
            r1 = timerMetricName mn
            r2 = timerMetricName r1
         in r1 === r2,
      testCase "adds time. prefix" $ do
        timerMetricName (MetricName "foo") @?= MetricName "time.foo"
    ]

-------------------------------------------------------------------------------
withRedisCleanup :: (IO Connection -> TestTree) -> TestTree
withRedisCleanup = withResource (connect redisCI) cleanup
  where
    cleanup conn = void $
      runRedis conn $ do
        ks <- either mempty id <$> smembers packetsKey
        _ <- del (packetsKey : ks)
        quit

-------------------------------------------------------------------------------
redisCI :: ConnectInfo
redisCI = defaultConnectInfo

icfg :: InstrumentConfig
icfg = def {redisQueueBound = Just 2}

key :: MetricName
key = MetricName "instrument-test"

dims :: Dimensions
dims = M.fromList [(DimensionName "server", DimensionValue "app1")]

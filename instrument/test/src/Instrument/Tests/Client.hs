{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Instrument.Tests.Client
    ( tests
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Default
import qualified Data.Map                   as M
import           Data.Monoid
import           Database.Redis
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
-------------------------------------------------------------------------------
import           Instrument.Client
import           Instrument.Tests.Arbitrary ()
import           Instrument.Types
import           Instrument.Worker
-------------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "Instrument.Client"
    [ withRedisCleanup $ testCase "queue bounding works" . queue_bounding_test
    , timerMetricNameTests
    ]

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
    void $ forkIO $ work conn 1 (AggProcess defAggProcessConfig (liftIO . putMVar agg))
    Aggregated { aggPayload = AggStats Stats {..} } <- takeMVar agg
    assertEqual "throws away newer data exceeding bounds"
                (2, 1, 1, 2)
                (scount, smin, smax, ssum)
  where
    sleepFlush =   threadDelay 1100000

timerMetricNameTests :: TestTree
timerMetricNameTests = testGroup "timerMetricName"
  [ testProperty "is idempotent" $ \mn ->
      let r1 = timerMetricName mn
          r2 =  timerMetricName r1
      in r1 === r2
  , testProperty "is idempotent for timers" $ \(MetricName mnBase) ->
      let mn = MetricName (timerMetricNamePrefix <> mnBase)
          r1 = timerMetricName mn
          r2 =  timerMetricName r1
      in r1 === r2
  , testCase "adds time. prefix" $ do
      timerMetricName (MetricName "foo") @?= MetricName "time.foo"
  ]


withRedisCleanup :: (IO Connection -> TestTree) -> TestTree
withRedisCleanup = withResource (connect redisCI) cleanup
  where
    cleanup conn = void $ runRedis conn $ do
      _ <- del ["_sq_instrument-test"]
      quit

redisCI :: ConnectInfo
redisCI = defaultConnectInfo

icfg :: InstrumentConfig
icfg = def { redisQueueBound = Just 2 }

key :: MetricName
key = MetricName "instrument-test"

dims :: Dimensions
dims = M.fromList [(DimensionName "server", DimensionValue "app1")]

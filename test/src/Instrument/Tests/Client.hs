{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Instrument.Tests.Client
    ( clientTests
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Default
import           Database.Redis
import           Test.Tasty
import           Test.Tasty.HUnit
-------------------------------------------------------------------------------
import           Instrument.Client
import           Instrument.Types
import           Instrument.Worker
-------------------------------------------------------------------------------

clientTests :: TestTree
clientTests = testGroup "Instrument.Client"
    [ withRedisCleanup $ testCase "queue bounding works" . queue_bounding_test
    ]

queue_bounding_test :: IO Connection -> IO ()
queue_bounding_test mkConn = do
    conn <- mkConn
    instr <- initInstrument redisCI icfg
    agg <- newEmptyMVar
    replicateM_ 2 (sampleI key 1 instr >> sleepFlush)
    -- redis queue slots now full of the above aggregate
    -- bounds will drop these
    sampleI key 100 instr
    sleepFlush
    void $ forkIO $ work conn 1 (liftIO . putMVar agg)
    Aggregated { aggPayload = AggStats Stats {..} } <- takeMVar agg
    assertEqual "throws away newer data exceeding bounds"
                (2, 1, 1, 2)
                (scount, smin, smax, ssum)
  where
    sleepFlush =   threadDelay 1100000

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

key :: String
key = "instrument-test"

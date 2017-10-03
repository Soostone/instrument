{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Instrument.Tests.Utils
    ( tests
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Monad
import qualified Data.ByteString       as B
import           Data.IORef
import qualified Data.Map              as M
import           Data.SafeCopy
import           Data.Serialize
import           Path
import qualified Path.IO               as PIO
import           System.Timeout
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
-------------------------------------------------------------------------------
import           Instrument.Types
import           Instrument.Utils
-------------------------------------------------------------------------------



tests :: TestTree
tests = testGroup "Instrument.Utils"
    [ encodeDecodeTests
    , withResource spawnWorker killWorker $ testCase "indefinitely retries" . indefinitely_retry
    ]


-------------------------------------------------------------------------------
encodeDecodeTests :: TestTree
encodeDecodeTests = testGroup "encodeCompress/decodeCompress"
  [ testProperty "encode/decode compress roundtrip" encode_decode_roundtrip
  , testCase "Stats decode" $
      testDecode $(mkRelFile "test/data/Instrument/Types/Stats.gz") stats
  , testCase "Payload decode" $
      testDecode $(mkRelFile "test/data/Instrument/Types/Payload.gz") payload
  , testCase "SubmissionPacket decode" $
      testDecode $(mkRelFile "test/data/Instrument/Types/SubmissionPacket.gz") submissionPacket
  , testCase "Aggregated decode" $
      testDecode $(mkRelFile "test/data/Instrument/Types/Aggregated.gz") aggregated
  ]
  where
    stats = Stats 1 2 3 4 5 6 7 8 9 (M.singleton 10 11)
    payload = Samples [1.2, 2.3, 4.5]
    submissionPacket = SP 3.4 "metric" payload (M.singleton hostDimension "example.org")
    aggregated = Aggregated 3.4 "metric" (AggStats stats) mempty
    testDecode :: forall a b. (Serialize a, SafeCopy a, Eq a, Show a) => Path b File -> a -> Assertion
    testDecode fp v = do
      exists <- PIO.doesFileExist fp
      unless exists $ do
        PIO.ensureDir (parent fp)
        B.writeFile (toFilePath fp) (encodeCompress v)
      res <- decodeCompress <$> B.readFile (toFilePath fp)
      (res :: Either String a) @?= Right v


-------------------------------------------------------------------------------
encode_decode_roundtrip :: String -> Property
encode_decode_roundtrip a = roundtrip a === Right a
  where
    roundtrip = decodeCompress . encodeCompress


-------------------------------------------------------------------------------
indefinitely_retry :: IO (MVar (), t1, t) -> IO ()
indefinitely_retry setup = do
    (called, _signal, _) <- setup
    wasCalled <- timeout (milliseconds 100) $ takeMVar called
    assertEqual "retries until success" (Just ()) wasCalled
  where


-------------------------------------------------------------------------------
spawnWorker :: IO (MVar (), IO (), ThreadId)
spawnWorker = do
  (called, signal) <- nopeNopeYep
  tid <- forkIO $ indefinitely "Test Worker" 0 signal
  return (called, signal, tid)


-------------------------------------------------------------------------------
killWorker :: (t1, t, ThreadId) -> IO ()
killWorker (_, _, tid) = killThread tid


-------------------------------------------------------------------------------
nopeNopeYep :: IO (MVar (), IO ())
nopeNopeYep = do
    counter <- newIORef (1 :: Int)
    mv <- newEmptyMVar
    return $ (mv, go counter mv)
  where
    go counter mv = do
      count <- readIORef counter
      modifyIORef' counter (+1)
      when (count > 2) $ void $ tryPutMVar mv ()


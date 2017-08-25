module Instrument.Tests.Utils
    ( utilsTests
    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Monad
import           Data.IORef
import           System.Timeout
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
-------------------------------------------------------------------------------
import           Instrument.Utils
-------------------------------------------------------------------------------



utilsTests :: TestTree
utilsTests = testGroup "Instrument.Utils"
    [ testProperty "encode/decode compress roundtrip" encode_decode_roundtrip
    , withResource spawnWorker killWorker $ testCase "indefinitely retries" . indefinitely_retry
    ]

encode_decode_roundtrip :: String -> Property
encode_decode_roundtrip a = roundtrip a === Right a
  where
    roundtrip = decodeCompress . encodeCompress

indefinitely_retry :: IO (MVar (), t1, t) -> IO ()
indefinitely_retry setup = do
    (called, _signal, _) <- setup
    wasCalled <- timeout (milliseconds 100) $ takeMVar called
    assertEqual "retries until success" (Just ()) wasCalled
  where

spawnWorker :: IO (MVar (), IO (), ThreadId)
spawnWorker = do
  (called, signal) <- nopeNopeYep
  tid <- forkIO $ indefinitely "Test Worker" 0 signal
  return (called, signal, tid)

killWorker :: (t1, t, ThreadId) -> IO ()
killWorker (_, _, tid) = killThread tid

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


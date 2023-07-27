{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Instrument.Tests.CloudWatch
  ( tests,
  )
where

-------------------------------------------------------------------------------
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMQueue
import qualified Data.Foldable as FT
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
-------------------------------------------------------------------------------
import Instrument.CloudWatch
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
      splitNETests
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

-------------------------------------------------------------------------------
mkQueue :: Int -> IO (TBMQueue String)
mkQueue = newTBMQueueIO

-------------------------------------------------------------------------------
splitNETests :: TestTree
splitNETests =
  testGroup
    "splitNE"
    [ testProperty "0 or negative count" $ \(NonEmpty nel) n ->
        n <= 0 ==>
          let ne = NE.fromList nel :: NonEmpty ()
           in splitNE n ne === ne :| [],
      testProperty "positive count, no items exceed length" $ \(NonEmpty nel) (Positive n) ->
        let ne = NE.fromList nel :: NonEmpty ()
            res = splitNE n ne
         in FT.all ((<= n) . NE.length) res,
      testProperty "positive count, loses no items and preserves order" $ \(NonEmpty nel) (Positive n) ->
        let ne = NE.fromList nel :: NonEmpty ()
            res = splitNE n ne
         in sconcat res === ne
    ]

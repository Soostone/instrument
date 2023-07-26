{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Instrument.Tests.Worker
  ( tests,
  )
where

-------------------------------------------------------------------------------
import qualified Data.Map as M
import Data.Monoid as Monoid
-------------------------------------------------------------------------------
import Instrument.Tests.Arbitrary ()
import Instrument.Types
import Instrument.Worker
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

-------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Instrument.Worker"
    [ expandDimsTests
    ]

-------------------------------------------------------------------------------
expandDimsTests :: TestTree
expandDimsTests =
  testGroup
    "expandDims"
    [ testProperty "input is a submap of output" $ \(Dims dims) ->
        let res = expandDims dims
         in counterexample
              ("Expected " <> show dims <> " to be a submap of " <> show res)
              (dims `M.isSubmapOf` res),
      testProperty "always includes an aggregate with no dimensions" $ \(Dims dims) ->
        let res = expandDims dims
         in M.member Monoid.mempty res,
      -- TODO: more and then a test of the worked example
      testProperty "no one member exceeds the total number of packets" $ \(Dims dims) ->
        let totalPacketCount = sum (length <$> dims)
            res = expandDims dims
            lengths = length <$> res
         in all (<= totalPacketCount) lengths,
      testCase "worked example from the readme" $ do
        let m =
              M.fromList
                [ (M.fromList [(d1, d1v1), (d2, d2v1)], [p1]),
                  (M.fromList [(d1, d1v1), (d2, d2v2)], [p2])
                ]
        let expected =
              M.fromList
                [ (M.fromList [(d1, d1v1), (d2, d2v1)], [p1]),
                  (M.fromList [(d1, d1v1), (d2, d2v2)], [p2]),
                  -- additions
                  (M.fromList [(d1, d1v1)], [p1, p2]),
                  (M.fromList [(d2, d2v1)], [p1]),
                  (M.fromList [(d2, d2v2)], [p2]),
                  (M.empty, [p1, p2])
                ]
        expandDims m @?= expected
    ]
  where
    d1 = DimensionName "d1"
    d2 = DimensionName "d2"
    d1v1 = DimensionValue "d1v1"
    d2v1 = DimensionValue "d2v1"
    d2v2 = DimensionValue "d2v2"
    p1 :: String
    p1 = "p1"
    p2 :: String
    p2 = "p2"

-- | Fixes the packet type for type inference
newtype Dims = Dims (M.Map Dimensions [Char])
  deriving (Show, Eq, Arbitrary)

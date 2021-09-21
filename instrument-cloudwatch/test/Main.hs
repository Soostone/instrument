module Main
  ( main,
  )
where

-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
import qualified Instrument.Tests.CloudWatch
import Test.Tasty

-------------------------------------------------------------------------------

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "instrument-cloudwatch"
    [ Instrument.Tests.CloudWatch.tests
    ]

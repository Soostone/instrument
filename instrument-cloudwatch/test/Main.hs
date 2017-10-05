module Main
    ( main
    ) where


-------------------------------------------------------------------------------
import           Test.Tasty
-------------------------------------------------------------------------------
import qualified Instrument.Tests.CloudWatch
-------------------------------------------------------------------------------


main :: IO ()
main = defaultMain tests



tests :: TestTree
tests = testGroup "instrument-cloudwatch"
  [
    Instrument.Tests.CloudWatch.tests
  ]

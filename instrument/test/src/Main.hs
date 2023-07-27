module Main (main) where

-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
import qualified Instrument.Tests.Client
import qualified Instrument.Tests.Counter
import qualified Instrument.Tests.Types
import qualified Instrument.Tests.Utils
import qualified Instrument.Tests.Worker
import Test.Tasty

-------------------------------------------------------------------------------

main :: IO ()
main =
  defaultMain $
    testGroup
      "tests"
      [ Instrument.Tests.Utils.tests,
        Instrument.Tests.Client.tests,
        Instrument.Tests.Types.tests,
        Instrument.Tests.Worker.tests,
        Instrument.Tests.Counter.tests
      ]

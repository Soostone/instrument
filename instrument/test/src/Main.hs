module Main (main) where

-------------------------------------------------------------------------------
import           Test.Tasty
-------------------------------------------------------------------------------
import qualified Instrument.Tests.Client
import qualified Instrument.Tests.Types
import qualified Instrument.Tests.Utils
-------------------------------------------------------------------------------

main :: IO ()
main = defaultMain $ testGroup "tests"
    [ Instrument.Tests.Utils.tests
    , Instrument.Tests.Client.tests
    , Instrument.Tests.Types.tests
    ]

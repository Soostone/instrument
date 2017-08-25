module Main (main) where

-------------------------------------------------------------------------------
import Test.Tasty
-------------------------------------------------------------------------------
import Instrument.Tests.Client (clientTests)
import Instrument.Tests.Types (typesTests)
import Instrument.Tests.Utils (utilsTests)
-------------------------------------------------------------------------------

main :: IO ()
main = defaultMain $ testGroup "tests"
    [ utilsTests
    , clientTests
    , typesTests
    ]

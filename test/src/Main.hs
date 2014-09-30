module Main (main) where

-------------------------------------------------------------------------------
import Test.Tasty
-------------------------------------------------------------------------------
import Instrument.Tests.Client (clientTests)
import Instrument.Tests.Utils (utilsTests)
-------------------------------------------------------------------------------

main = defaultMain $ testGroup "tests"
    [ utilsTests
    , clientTests
    ]

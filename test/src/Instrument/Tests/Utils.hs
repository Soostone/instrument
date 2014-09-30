module Instrument.Tests.Utils
    ( utilsTests
    ) where

-------------------------------------------------------------------------------
import Test.Tasty
import Test.Tasty.QuickCheck
-------------------------------------------------------------------------------
import Instrument.Utils
-------------------------------------------------------------------------------



utilsTests = testGroup "Instrument.Utils"
    [ testProperty "encode/decode compress roundtrip" encode_decode_roundtrip
    ]

encode_decode_roundtrip :: String -> Property
encode_decode_roundtrip a = roundtrip a === Right a
  where
    roundtrip = decodeCompress . encodeCompress

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Instrument.Tests.Types
  ( tests,
  )
where

-------------------------------------------------------------------------------
import qualified Data.Map as M
-------------------------------------------------------------------------------
import Instrument.Types
import Path
import Test.HUnit.SafeCopy
import Test.Tasty
import Test.Tasty.HUnit

-------------------------------------------------------------------------------

--TODO: test parse of .serialize files

tests :: TestTree
tests =
  testGroup
    "Instrument.Types"
    [ testCase "Stats SafeCopy" $
        testSafeCopy FailMissingFiles $(mkRelFile "test/data/Instrument/Types/Stats.safecopy") stats,
      testCase "Payload SafeCopy" $
        testSafeCopy FailMissingFiles $(mkRelFile "test/data/Instrument/Types/Payload.safecopy") payload,
      testCase "SubmissionPacket SafeCopy" $
        testSafeCopy FailMissingFiles $(mkRelFile "test/data/Instrument/Types/SubmissionPacket.safecopy") submissionPacket,
      testCase "Aggregated SafeCopy" $
        testSafeCopy FailMissingFiles $(mkRelFile "test/data/Instrument/Types/Aggregated.safecopy") aggregated
    ]
  where
    stats = Stats 1 2 3 4 5 6 7 8 9 (M.singleton 10 11)
    payload = Samples [1.2, 2.3, 4.5]
    submissionPacket = SP 3.4 "metric" payload (M.singleton hostDimension "example.org")
    aggregated = Aggregated 3.4 "metric" (AggStats stats) mempty

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Instrument.Tests.Arbitrary
  (
  )
where

-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
import Instrument.Types
import Test.QuickCheck
import Test.QuickCheck.Instances ()

-------------------------------------------------------------------------------

instance Arbitrary DimensionName where
  arbitrary = DimensionName <$> arbitrary

instance Arbitrary DimensionValue where
  arbitrary = DimensionValue <$> arbitrary

instance Arbitrary MetricName where
  arbitrary = MetricName <$> arbitrary

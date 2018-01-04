{-# OPTIONS_GHC -fno-warn-orphans #-}
module Instrument.Tests.Arbitrary
    (
    ) where


-------------------------------------------------------------------------------
import           Test.QuickCheck
import           Test.QuickCheck.Instances ()
-------------------------------------------------------------------------------
import           Instrument.Types
-------------------------------------------------------------------------------


instance Arbitrary DimensionName where
  arbitrary = DimensionName <$> arbitrary


instance Arbitrary DimensionValue where
  arbitrary = DimensionValue <$> arbitrary


instance Arbitrary MetricName where
  arbitrary = MetricName <$> arbitrary

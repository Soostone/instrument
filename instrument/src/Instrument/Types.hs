{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Instrument.Types
  ( createInstrumentPool,
    Samplers,
    Counters,
    Instrument (..),
    InstrumentConfig (..),
    SubmissionPacket (..),
    MetricName (..),
    DimensionName (..),
    DimensionValue (..),
    Dimensions,
    Payload (..),
    Aggregated (..),
    AggPayload (..),
    Stats (..),
    hostDimension,
    HostDimensionPolicy (..),
    Quantile (..),
  )
where

-------------------------------------------------------------------------------
import Control.Applicative as A
import qualified Data.ByteString.Char8 as B
import Data.Default
import Data.IORef
import qualified Data.Map as M
import Data.Monoid as Monoid
import qualified Data.SafeCopy as SC
import Data.Serialize as Ser
import Data.Serialize.Text ()
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Database.Redis as R
import GHC.Generics
-------------------------------------------------------------------------------
import qualified Instrument.Counter as C
import qualified Instrument.Sampler as S
import Network.HostName

-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
createInstrumentPool :: ConnectInfo -> IO Connection
createInstrumentPool ci =
  connect
    ci
      { connectMaxIdleTime = 15,
        connectMaxConnections = 1
      }

-------------------------------------------------------------------------------

newtype DimensionName = DimensionName
  { dimensionName :: Text
  }
  deriving (Eq, Ord, Show, Generic, Serialize, IsString)

$(SC.deriveSafeCopy 0 'SC.base ''DimensionName)

-- | Convention for the dimension of the hostname. Used in the client
-- to inject hostname into the parameters map
hostDimension :: DimensionName
hostDimension = "host"

newtype DimensionValue = DimensionValue
  { dimensionValue :: Text
  }
  deriving (Eq, Ord, Show, Generic, Serialize, IsString)

$(SC.deriveSafeCopy 0 'SC.base ''DimensionValue)

newtype MetricName = MetricName
  { metricName :: String
  }
  deriving (Eq, Show, Generic, Ord, IsString, Serialize)

$(SC.deriveSafeCopy 0 'SC.base ''MetricName)

-------------------------------------------------------------------------------

-- Map of user-defined samplers.
type Samplers = M.Map (MetricName, Dimensions) S.Sampler

-- Map of user-defined counters.
type Counters = M.Map (MetricName, Dimensions) C.Counter

type Dimensions = M.Map DimensionName DimensionValue

data Payload_v0
  = Samples_v0 {unSamples_v0 :: [Double]}
  | Counter_v0 {unCounter_v0 :: Int}
  deriving (Eq, Show, Generic)

instance Serialize Payload_v0

data Payload
  = Samples {unSamples :: [Double]}
  | Counter {unCounter :: Integer}
  deriving (Eq, Show, Generic)

instance Serialize Payload

$(SC.deriveSafeCopy 0 'SC.base ''Payload_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''Payload)

instance SC.Migrate Payload where
  type MigrateFrom Payload = Payload_v0
  migrate (Samples_v0 n) = Samples n
  migrate (Counter_v0 n) = Counter $ fromIntegral n

data Instrument = I
  { hostName :: HostName,
    samplers :: !(IORef Samplers),
    counters :: !(IORef Counters),
    redis :: Connection
  }

newtype InstrumentConfig = ICfg
  { redisQueueBound :: Maybe Integer
  }

instance Default InstrumentConfig where
  def = ICfg Nothing

-- | Submitted package of collected samples
data SubmissionPacket_v0 = SP_v0
  { -- | Timing of this submission
    spTimeStamp_v0 :: !Double,
    -- | Who sent it
    spHostName_v0 :: !HostName,
    -- | Metric name
    spName_v0 :: String,
    -- | Collected values
    spPayload_v0 :: Payload
  }
  deriving (Eq, Show, Generic)

instance Serialize SubmissionPacket_v0

data SubmissionPacket_v1 = SP_v1
  { -- | Timing of this submission
    spTimeStamp_v1 :: !Double,
    -- | Metric name
    spName_v1 :: !MetricName,
    -- | Collected values
    spPayload_v1 :: !Payload_v0,
    -- | Defines slices that this packet belongs to. This allows
    -- drill-down on the backends. For instance, you could do
    -- "server_name" "app1" or "queue_name" "my_queue"
    spDimensions_v1 :: !Dimensions
  }
  deriving (Eq, Show, Generic)

instance Serialize SubmissionPacket_v1

data SubmissionPacket = SP
  { -- | Timing of this submission
    spTimeStamp :: !Double,
    -- | Metric name
    spName :: !MetricName,
    -- | Collected values
    spPayload :: !Payload,
    -- | Defines slices that this packet belongs to. This allows
    -- drill-down on the backends. For instance, you could do
    -- "server_name" "app1" or "queue_name" "my_queue"
    spDimensions :: !Dimensions
  }
  deriving (Eq, Show, Generic)

instance Serialize SubmissionPacket where
  get = (to <$> gGet) <|> (upgradeSP1 <$> Ser.get) <|> (upgradeSP0 <$> Ser.get)

upgradeSP0 :: SubmissionPacket_v0 -> SubmissionPacket
upgradeSP0 SP_v0 {..} =
  SP
    { spTimeStamp = spTimeStamp_v0,
      spName = MetricName spName_v0,
      spPayload = spPayload_v0,
      spDimensions = M.singleton hostDimension (DimensionValue (T.pack spHostName_v0))
    }

upgradeSP1 :: SubmissionPacket_v1 -> SubmissionPacket
upgradeSP1 SP_v1 {..} =
  SP
    { spTimeStamp = spTimeStamp_v1,
      spName = spName_v1,
      spPayload = case spPayload_v1 of
        Samples_v0 n -> Samples n
        Counter_v0 n -> Counter $ fromIntegral n,
      spDimensions = spDimensions_v1
    }

$(SC.deriveSafeCopy 0 'SC.base ''SubmissionPacket_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''SubmissionPacket)

instance SC.Migrate SubmissionPacket where
  type MigrateFrom SubmissionPacket = SubmissionPacket_v0
  migrate = upgradeSP0

-------------------------------------------------------------------------------

-- | Should we automatically pull the host and add it as a
-- dimension. Used at the call site of the various metrics ('timeI',
-- 'sampleI', etc). Hosts are basically grandfathered in as a
-- dimension and the functionality of automatically injecting them is
-- useful, but it is not relevant to some metrics and actually makes
-- some metrics difficult to use depending on the backend, so we made
-- them opt-in.
data HostDimensionPolicy
  = AddHostDimension
  | DoNotAddHostDimension
  deriving (Show, Eq)

-------------------------------------------------------------------------------
data Stats = Stats
  { smean :: Double,
    ssum :: Double,
    scount :: Int,
    smax :: Double,
    smin :: Double,
    srange :: Double,
    sstdev :: Double,
    sskewness :: Double,
    skurtosis :: Double,
    squantiles :: M.Map Int Double
  }
  deriving (Eq, Show, Generic)

instance Default Stats where
  def = Stats 0 0 0 0 0 0 0 0 0 mempty

instance Serialize Stats

$(SC.deriveSafeCopy 0 'SC.base ''Stats)

-------------------------------------------------------------------------------

-- | Resulting payload for metrics aggregation
data AggPayload_v0
  = AggStats_v0 Stats
  | AggCount_v0 Int
  deriving (Eq, Show, Generic)

instance Serialize AggPayload_v0

data AggPayload
  = AggStats Stats
  | AggCount Integer
  deriving (Eq, Show, Generic)

instance Serialize AggPayload

instance Default AggPayload where
  def = AggStats def

$(SC.deriveSafeCopy 0 'SC.base ''AggPayload_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''AggPayload)

instance SC.Migrate AggPayload where
  type MigrateFrom AggPayload = AggPayload_v0
  migrate (AggStats_v0 n) = AggStats n
  migrate (AggCount_v0 n) = AggCount $ fromIntegral n

-------------------------------------------------------------------------------
data Aggregated = Aggregated
  { -- | Timestamp for this aggregation
    aggTS :: Double,
    -- | Name of the metric
    aggName :: MetricName,
    -- | Calculated stats for the metric
    aggPayload :: AggPayload,
    aggDimensions :: Dimensions
  }
  deriving (Eq, Show, Generic)

instance Serialize Aggregated where
  get = (to <$> gGet) <|> (upgradeAggregated_v2 <$> Ser.get) <|> (upgradeAggregated_v2 . upgradeAggregated_v1 <$> Ser.get)

instance Default Aggregated where
  def = Aggregated 0 "" def mempty

data Aggregated_v2 = Aggregated_v2
  { -- | Timestamp for this aggregation
    aggTS_v2 :: Double,
    -- | Name of the metric
    aggName_v2 :: MetricName,
    -- | Calculated stats for the metric
    aggPayload_v2 :: AggPayload_v0,
    aggDimensions_v2 :: Dimensions
  }
  deriving (Eq, Show, Generic)

instance Serialize Aggregated_v2

upgradeAggregated_v2 :: Aggregated_v2 -> Aggregated
upgradeAggregated_v2 a =
  Aggregated
    { aggTS = aggTS_v2 a,
      aggName = aggName_v2 a,
      aggPayload = SC.migrate (aggPayload_v2 a),
      aggDimensions = aggDimensions_v2 a
    }

data Aggregated_v1 = Aggregated_v1
  { -- | Timestamp for this aggregation
    aggTS_v1 :: Double,
    -- | Name of the metric
    aggName_v1 :: MetricName,
    -- | The aggregation level/group for this stat
    aggGroup_v1 :: B.ByteString,
    -- | Calculated stats for the metric
    aggPayload_v1 :: AggPayload_v0
  }
  deriving (Eq, Show, Generic)

upgradeAggregated_v1 :: Aggregated_v1 -> Aggregated_v2
upgradeAggregated_v1 a =
  Aggregated_v2
    { aggTS_v2 = aggTS_v1 a,
      aggName_v2 = aggName_v1 a,
      aggPayload_v2 = aggPayload_v1 a,
      aggDimensions_v2 = Monoid.mempty
    }

data Aggregated_v0 = Aggregated_v0
  { -- | Timestamp for this aggregation
    aggTS_v0 :: Double,
    -- | Name of the metric
    aggName_v0 :: String,
    -- | The aggregation level/group for this stat
    aggGroup_v0 :: B.ByteString,
    -- | Calculated stats for the metric
    aggPayload_v0 :: AggPayload_v0
  }
  deriving (Eq, Show, Generic)

instance Serialize Aggregated_v0

upgradeAggregated_v0 :: Aggregated_v0 -> Aggregated_v1
upgradeAggregated_v0 a =
  Aggregated_v1
    { aggTS_v1 = aggTS_v0 a,
      aggName_v1 = MetricName (aggName_v0 a),
      aggGroup_v1 = aggGroup_v0 a,
      aggPayload_v1 = aggPayload_v0 a
    }

instance Serialize Aggregated_v1 where
  get = (to <$> gGet) <|> (upgradeAggregated_v0 <$> Ser.get)

$(SC.deriveSafeCopy 0 'SC.base ''Aggregated_v0)

instance SC.Migrate Aggregated_v1 where
  type MigrateFrom Aggregated_v1 = Aggregated_v0
  migrate = upgradeAggregated_v0

$(SC.deriveSafeCopy 1 'SC.extension ''Aggregated_v1)

instance SC.Migrate Aggregated_v2 where
  type MigrateFrom Aggregated_v2 = Aggregated_v1
  migrate = upgradeAggregated_v1

$(SC.deriveSafeCopy 2 'SC.extension ''Aggregated_v2)

instance SC.Migrate Aggregated where
  type MigrateFrom Aggregated = Aggregated_v2
  migrate = upgradeAggregated_v2

$(SC.deriveSafeCopy 3 'SC.extension ''Aggregated)

-------------------------------------------------------------------------------

-- | Integer quantile, valid values range from 1-99, inclusive.
newtype Quantile = Q {quantile :: Int} deriving (Show, Eq, Ord)

instance Bounded Quantile where
  minBound = Q 1
  maxBound = Q 99

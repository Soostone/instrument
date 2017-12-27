{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module Instrument.Types
  ( createInstrumentPool
  , Samplers
  , Counters
  , Instrument(..)
  , InstrumentConfig(..)
  , SubmissionPacket(..)
  , MetricName(..)
  , DimensionName(..)
  , DimensionValue(..)
  , Dimensions
  , Payload(..)
  , Aggregated(..)
  , AggPayload(..)
  , Stats(..)
  , hostDimension
  , HostDimensionPolicy(..)
  ) where

-------------------------------------------------------------------------------
import           Control.Applicative   as A
import qualified Data.ByteString.Char8 as B
import           Data.Default
import           Data.IORef
import qualified Data.Map              as M
import           Data.Monoid           as Monoid
import qualified Data.SafeCopy         as SC
import           Data.Serialize
import           Data.Serialize.Text   ()
import           Data.String
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Database.Redis        as H hiding (HostName, get)
import           GHC.Generics
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Counter    as C
import qualified Instrument.Sampler    as S
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
createInstrumentPool :: ConnectInfo -> IO Connection
createInstrumentPool ci = do
  c <- connect ci {
         connectMaxIdleTime = 15
       , connectMaxConnections = 1 }
  return c


-- Map of user-defined samplers.
type Samplers = M.Map (MetricName, Dimensions) S.Sampler

-- Map of user-defined counters.
type Counters = M.Map (MetricName, Dimensions) C.Counter


type Dimensions = M.Map DimensionName DimensionValue


newtype MetricName = MetricName {
      metricName :: String
    } deriving (Eq,Show,Generic,Ord,IsString,Serialize)


data Instrument = I {
      hostName :: HostName
    , samplers :: !(IORef Samplers)
    , counters :: !(IORef Counters)
    , redis    :: Connection
    }

data InstrumentConfig = ICfg {
      redisQueueBound :: Maybe Integer
    }

instance Default InstrumentConfig where
  def = ICfg Nothing


-- | Submitted package of collected samples
data SubmissionPacket_v0 = SP_v0 {
      spTimeStamp_v0 :: !Double
    -- ^ Timing of this submission
    , spHostName_v0  :: !HostName
    -- ^ Who sent it
    , spName_v0      :: String
    -- ^ Metric name
    , spPayload_v0   :: Payload
    -- ^ Collected values
    } deriving (Eq,Show,Generic)


instance Serialize SubmissionPacket_v0


data SubmissionPacket = SP {
      spTimeStamp  :: !Double
    -- ^ Timing of this submission
    , spName       :: !MetricName
    -- ^ Metric name
    , spPayload    :: !Payload
    -- ^ Collected values
    , spDimensions :: !Dimensions
    -- ^ Defines slices that this packet belongs to. This allows
    -- drill-down on the backends. For instance, you could do
    -- "server_name" "app1" or "queue_name" "my_queue"
    } deriving (Eq,Show,Generic)


instance Serialize SubmissionPacket where
  get = (to <$> gGet) <|> (upgradeSP0 <$> get)


instance SC.Migrate SubmissionPacket where
  type MigrateFrom SubmissionPacket = SubmissionPacket_v0
  migrate = upgradeSP0


upgradeSP0 :: SubmissionPacket_v0 -> SubmissionPacket
upgradeSP0 SP_v0 {..} = SP
  { spTimeStamp = spTimeStamp_v0
  , spName = MetricName spName_v0
  , spPayload = spPayload_v0
  , spDimensions = M.singleton hostDimension (DimensionValue (T.pack spHostName_v0))
  }


-------------------------------------------------------------------------------
-- | Convention for the dimension of the hostname. Used in the client
-- to inject hostname into the parameters map
hostDimension :: DimensionName
hostDimension = "host"


-------------------------------------------------------------------------------
-- | Should we automatically pull the host and add it as a
-- dimension. Used at the call site of the various metrics ('timeI',
-- 'sampleI', etc). Hosts are basically grandfathered in as a
-- dimension and the functionality of automatically injecting them is
-- useful, but it is not relevant to some metrics and actually makes
-- some metrics difficult to use depending on the backend, so we made
-- them opt-in.
data HostDimensionPolicy = AddHostDimension
                         | DoNotAddHostDimension
                         deriving (Show, Eq)


-------------------------------------------------------------------------------
newtype DimensionName = DimensionName {
    dimensionName :: Text
  } deriving (Eq,Ord,Show,Generic,Serialize,IsString)


-------------------------------------------------------------------------------
newtype DimensionValue = DimensionValue {
    dimensionValue :: Text
  } deriving (Eq,Ord,Show,Generic,Serialize,IsString)


-------------------------------------------------------------------------------
data Payload
    = Samples { unSamples :: [Double] }
    | Counter { unCounter :: Int }
  deriving (Eq, Show, Generic)

instance Serialize Payload


-------------------------------------------------------------------------------
data Aggregated_v0 = Aggregated_v0 {
      aggTS_v0      :: Double
      -- ^ Timestamp for this aggregation
    , aggName_v0    :: String
    -- ^ Name of the metric
    , aggGroup_v0   :: B.ByteString
    -- ^ The aggregation level/group for this stat
    , aggPayload_v0 :: AggPayload
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show,Generic)


instance Serialize Aggregated_v0


data Aggregated_v1 = Aggregated_v1 {
      aggTS_v1      :: Double
      -- ^ Timestamp for this aggregation
    , aggName_v1    :: MetricName
    -- ^ Name of the metric
    , aggGroup_v1   :: B.ByteString
    -- ^ The aggregation level/group for this stat
    , aggPayload_v1 :: AggPayload
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show,Generic)


instance SC.Migrate Aggregated_v1 where
  type MigrateFrom Aggregated_v1 = Aggregated_v0
  migrate = upgradeAggregated_v0


upgradeAggregated_v0 :: Aggregated_v0 -> Aggregated_v1
upgradeAggregated_v0 a = Aggregated_v1
  { aggTS_v1 = aggTS_v0 a
  , aggName_v1 = MetricName (aggName_v0 a)
  , aggGroup_v1 = (aggGroup_v0 a)
  , aggPayload_v1 = (aggPayload_v0 a)
  }

instance Serialize Aggregated_v1 where
  get = (to <$> gGet) <|> (upgradeAggregated_v0 <$> get)


data Aggregated = Aggregated {
      aggTS         :: Double
      -- ^ Timestamp for this aggregation
    , aggName       :: MetricName
    -- ^ Name of the metric
    , aggPayload    :: AggPayload
    -- ^ Calculated stats for the metric
    , aggDimensions :: Dimensions
    } deriving (Eq,Show, Generic)


upgradeAggregated_v1 :: Aggregated_v1 -> Aggregated
upgradeAggregated_v1 a = Aggregated
  { aggTS = aggTS_v1 a
  , aggName = aggName_v1 a
  , aggPayload = aggPayload_v1 a
  , aggDimensions = Monoid.mempty
  }


instance SC.Migrate Aggregated where
  type MigrateFrom Aggregated = Aggregated_v1
  migrate = upgradeAggregated_v1


instance Serialize Aggregated where
  get = (to <$> gGet) <|> (upgradeAggregated_v1 <$> get)


-- | Resulting payload for metrics aggregation
data AggPayload
    = AggStats Stats
    | AggCount Int
    deriving (Eq,Show, Generic)

instance Serialize AggPayload




instance Default AggPayload where
    def = AggStats def

instance Default Aggregated where
    def = Aggregated 0 "" def mempty


-------------------------------------------------------------------------------
data Stats = Stats {
      smean      :: Double
    , ssum       :: Double
    , scount     :: Int
    , smax       :: Double
    , smin       :: Double
    , srange     :: Double
    , sstdev     :: Double
    , sskewness  :: Double
    , skurtosis  :: Double
    , squantiles :: M.Map Int Double
    } deriving (Eq, Show, Generic)



instance Default Stats where
    def = Stats 0 0 0 0 0 0 0 0 0 mempty

instance Serialize Stats



$(SC.deriveSafeCopy 0 'SC.base ''Payload)
$(SC.deriveSafeCopy 0 'SC.base ''SubmissionPacket_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''SubmissionPacket)
$(SC.deriveSafeCopy 0 'SC.base ''AggPayload)
$(SC.deriveSafeCopy 0 'SC.base ''Aggregated_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''Aggregated_v1)
$(SC.deriveSafeCopy 2 'SC.extension ''Aggregated)
$(SC.deriveSafeCopy 0 'SC.base ''Stats)
$(SC.deriveSafeCopy 0 'SC.base ''DimensionName)
$(SC.deriveSafeCopy 0 'SC.base ''DimensionValue)
$(SC.deriveSafeCopy 0 'SC.base ''MetricName)

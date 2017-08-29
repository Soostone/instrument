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
  , mkStatsFields
  , aggToCSV
  , Stats(..)
  ) where

-------------------------------------------------------------------------------
import           Control.Applicative   as A
import qualified Data.ByteString.Char8 as B
import           Data.CSV.Conduit
import           Data.Default
import           Data.IORef
import qualified Data.Map              as M
import qualified Data.SafeCopy         as SC
import           Data.Serialize
import           Data.Serialize.Text   ()
import           Data.String
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Text.Encoding
import           Database.Redis        as H hiding (HostName, get)
import           GHC.Generics
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Counter    as C
import qualified Instrument.Sampler    as S
import           Instrument.Utils
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
    , spHostName   :: !HostName
    -- ^ Who sent it. Note that on the backend this is converted to a
    -- dimension.
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
  , spHostName = spHostName_v0
  , spName = MetricName spName_v0
  , spPayload = spPayload_v0
  , spDimensions = mempty
  }


-------------------------------------------------------------------------------
newtype DimensionName = DimensionName {
    dimensionName :: Text
  } deriving (Eq,Ord,Show,Generic,Serialize)


-------------------------------------------------------------------------------
newtype DimensionValue = DimensionValue {
    dimensionValue :: Text
  } deriving (Eq,Ord,Show,Generic,Serialize)


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
    } deriving (Eq,Show, Generic)

instance Serialize Aggregated


data Aggregated = Aggregated {
      aggTS      :: Double
      -- ^ Timestamp for this aggregation
    , aggName    :: MetricName
    -- ^ Name of the metric
    , aggGroup   :: B.ByteString
    -- ^ The aggregation level/group for this stat
    , aggPayload :: AggPayload
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show, Generic)


instance SC.Migrate Aggregated where
  type MigrateFrom Aggregated = Aggregated_v0
  migrate Aggregated_v0 {..} = Aggregated
    { aggTS = aggTS_v0
    , aggName = MetricName aggName_v0
    , aggGroup = aggGroup_v0
    , aggPayload = aggPayload_v0
    }


-- | Resulting payload for metrics aggregation
data AggPayload
    = AggStats Stats
    | AggCount Int
    deriving (Eq,Show, Generic)

instance Serialize AggPayload




instance Default AggPayload where
    def = AggStats def

instance Default Aggregated where
    def = Aggregated 0 "" "" def


-------------------------------------------------------------------------------
-- | Get agg results into a form ready to be output
mkStatsFields :: Aggregated -> ([(Text, Text)], Text)
mkStatsFields Aggregated{..}  = (els, ts)
    where
      els =
        case aggPayload of
          AggStats Stats{..} ->
              [ ("mean", formatDecimal 6 False smean)
              , ("count", showT scount)
              , ("max", formatDecimal 6 False smax)
              , ("min", formatDecimal 6 False smin)
              , ("srange", formatDecimal 6 False srange)
              , ("stdDev", formatDecimal 6 False sstdev)
              , ("sum", formatDecimal 6 False ssum)
              , ("skewness", formatDecimal 6 False sskewness)
              , ("kurtosis", formatDecimal 6 False skurtosis)
              ] ++ (map mkQ $ M.toList squantiles)
          AggCount i ->
              [ ("count", showT i)]

      mkQ (k,v) = (T.concat ["percentile_", showT k], formatDecimal 6 False v)
      ts = formatInt aggTS


-------------------------------------------------------------------------------
-- | Expand count aggregation to have the full columns
aggToCSV :: Aggregated -> M.Map Text Text
aggToCSV agg@Aggregated{..} = M.union els defFields
  where
    els :: MapRow Text
    els = M.fromList $
            ("metric", T.pack (metricName aggName)) :
            ("group", decodeUtf8 aggGroup ) :
            ("timestamp", ts) :
            fields
    (fields, ts) = mkStatsFields agg
    defFields = M.fromList $ fst $ mkStatsFields $ agg { aggPayload =  (AggStats def) }



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
    def = Stats 0 0 0 0 0 0 0 0 0 (M.fromList $ mkQ 99 : map (mkQ . (* 10)) [1..9])
      where
        mkQ i = (i, 0)

instance Serialize Stats



$(SC.deriveSafeCopy 0 'SC.base ''Payload)
$(SC.deriveSafeCopy 0 'SC.base ''SubmissionPacket_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''SubmissionPacket)
$(SC.deriveSafeCopy 0 'SC.base ''AggPayload)
$(SC.deriveSafeCopy 0 'SC.base ''Aggregated_v0)
$(SC.deriveSafeCopy 1 'SC.extension ''Aggregated)
$(SC.deriveSafeCopy 0 'SC.base ''Stats)
$(SC.deriveSafeCopy 0 'SC.base ''DimensionName)
$(SC.deriveSafeCopy 0 'SC.base ''DimensionValue)
$(SC.deriveSafeCopy 0 'SC.base ''MetricName)

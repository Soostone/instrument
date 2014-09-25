{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module Instrument.Types where

-------------------------------------------------------------------------------
import qualified Data.ByteString.Char8 as B
import           Data.CSV.Conduit
import           Data.Default
import           Data.IORef
import qualified Data.Map              as M
import           Data.Serialize
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
type Samplers = M.Map String S.Sampler

-- Map of user-defined counters.
type Counters = M.Map String C.Counter


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
data SubmissionPacket = SP {
      spTimeStamp :: !Double
    -- ^ Timing of this submission
    , spHostName  :: !HostName
    -- ^ Who sent it
    , spName      :: String
    -- ^ Metric name
    , spPayload   :: Payload
    -- ^ Collected values
    } deriving (Eq,Show,Generic)

instance Serialize SubmissionPacket


-------------------------------------------------------------------------------
data Payload
    = Samples { unSamples :: [Double] }
    | Counter { unCounter :: Int }
  deriving (Eq, Show, Generic)

instance Serialize Payload

-------------------------------------------------------------------------------
data Aggregated = Aggregated {
      aggTS      :: Double
      -- ^ Timestamp for this aggregation
    , aggName    :: String
    -- ^ Name of the metric
    , aggGroup   :: B.ByteString
    -- ^ The aggregation level/group for this stat
    , aggPayload :: AggPayload
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show, Generic)

instance Serialize Aggregated


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
aggToCSV agg@Aggregated{..} = M.union els defFields
  where
    els :: MapRow Text
    els = M.fromList $
            ("metric", T.pack aggName) :
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



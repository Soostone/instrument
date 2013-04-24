{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module Instrument.Types where

-------------------------------------------------------------------------------
import           Control.Concurrent (ThreadId)
import           Data.CSV.Conduit
import           Data.Default
import           Data.DeriveTH
import           Data.IORef         (IORef, atomicModifyIORef, newIORef,
                                     readIORef)
import qualified Data.Map           as M
import           Data.Serialize
import qualified Data.Text          as T
import qualified Data.Text.Encoding as T
import           Database.Redis     as H hiding (HostName (..), get)
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Counter as C
import qualified Instrument.Sampler as S
import           Instrument.Utils
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
createInstrumentPool :: ConnectInfo -> IO Connection
createInstrumentPool ci = do
  c <- connect ci {
         connectMaxIdleTime = 300
       , connectMaxConnections = 3 }
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
    }


-------------------------------------------------------------------------------
data Payload
    = Samples { unSamples :: [Double] }
    | Counter { unCounter :: Int }


-------------------------------------------------------------------------------
data Aggregated = Aggregated {
      aggTS      :: Double
      -- ^ Timestamp for this aggregation
    , aggName    :: String
    -- ^ Name of the metric
    , aggGroup   :: T.Text
    -- ^ The aggregation level/group for this stat
    , aggPayload :: AggPayload
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show)


-- | Resulting payload for metrics aggregation
data AggPayload
    = AggStats Stats
    | AggCount Int
    deriving (Eq,Show)


instance Default AggPayload where
    def = AggStats def

instance Default Aggregated where
    def = Aggregated 0 "" "" def


-------------------------------------------------------------------------------
-- | Get agg results into a form ready to be outputted
mkStatsFields :: Aggregated -> ([(T.Text, T.Text)], T.Text)
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
aggToCSV agg@Aggregated{..} = els
  where
    els :: MapRow T.Text
    els = M.fromList $ ("metric", T.pack aggName) : ("timestamp", ts) : ss
    (ss, ts) = mkStatsFields agg



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
    } deriving (Eq, Show)



instance Default Stats where
    def = Stats 0 0 0 0 0 0 0 0 0 (M.fromList $ mkQ 99 : map (mkQ . (* 10)) [1..9])
      where
        mkQ i = (i, 0)



$(derives [makeSerialize] [''Stats, ''SubmissionPacket
                          , ''Payload, ''AggPayload])



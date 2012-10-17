{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module Instrument.Types where

-------------------------------------------------------------------------------
import           Control.Concurrent  (ThreadId)
import           Data.CSV.Conduit
import           Data.Default
import           Data.DeriveTH
import           Data.IORef          (IORef, atomicModifyIORef, newIORef, readIORef)
import qualified Data.Map as M
import           Data.Serialize
import qualified Data.Text           as T
import qualified Data.Text.Encoding  as T
import           Database.Redis      as H hiding (HostName(..), get)
import           Network.HostName
-------------------------------------------------------------------------------
import qualified Instrument.Sampler  as S
import Instrument.Utils
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
createInstrumentPool :: ConnectInfo -> IO Connection
createInstrumentPool ci = do
  c <- connect ci {
         connectMaxIdleTime = 300
       , connectMaxConnections = 3 }
  return c


-- Map of user-defined samplers.
type Samplers = M.Map T.Text S.Sampler


data Instrument = I {
      threadId :: !ThreadId
    , hostName :: HostName
    , samplers :: !(IORef Samplers)
    , redis :: Connection
    }


data SubmissionPacket = SP {
      spTimeStamp :: !Double
    -- ^ Timing of this submission
    , spHostName :: !HostName
    -- ^ Who sent it
    , spName :: !T.Text
    -- ^ Metric name
    , spVals :: [Double]
    -- ^ Collected values
    }


-------------------------------------------------------------------------------
data Aggregated = Aggregated {
      aggTS :: Double
      -- ^ Timestamp for this aggregation
    , aggName :: T.Text
    -- ^ Name of the metric
    , aggStats :: Stats
    -- ^ Calculated stats for the metric
    } deriving (Eq,Show)


instance Default Aggregated where
    def = Aggregated 0 "" def


-------------------------------------------------------------------------------
aggToCSV Aggregated{..} = els
  where
    Stats{..} = aggStats
    els :: MapRow T.Text
    els = M.fromList $
      [ ("mean", formatDecimal 6 False smean)
      , ("count", showT scount)
      , ("max", formatDecimal 6 False smax)
      , ("min", formatDecimal 6 False smin)
      , ("srange", formatDecimal 6 False srange)
      , ("stdDev", formatDecimal 6 False sstdev)
      , ("metric", aggName)
      , ("timestamp", formatInt aggTS)
      , ("sum", formatDecimal 6 False ssum)
      , ("skewness", formatDecimal 6 False sskewness)
      , ("kurtosis", formatDecimal 6 False skurtosis)
      ] ++ qs
    qs = map mkQ $ M.toList squantiles
    mkQ (k,v) = (T.concat ["quantile_", showT k], formatDecimal 6 False v)


-------------------------------------------------------------------------------
data Stats = Stats {
      smean :: Double
    , ssum :: Double
    , scount :: Int
    , smax :: Double
    , smin :: Double
    , srange :: Double
    , sstdev :: Double
    , sskewness :: Double
    , skurtosis :: Double
    , squantiles :: M.Map Int Double
    } deriving (Eq, Show)



instance Default Stats where
    def = Stats 0 0 0 0 0 0 0 0 0 (M.fromList $ mkQ 99 : map (mkQ . (* 10)) [1..9])
      where
        mkQ i = (i, 0)


-------------------------------------------------------------------------------
instance Serialize T.Text where
    put = put . T.encodeUtf8
    get = T.decodeUtf8 `fmap` get



$(derives [makeSerialize] [''Aggregated, ''Stats, ''SubmissionPacket])



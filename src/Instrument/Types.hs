{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

module Instrument.Types where

-------------------------------------------------------------------------------
import           Control.Concurrent   (ThreadId)
import           Data.Aeson
import           Data.Aeson.TH
import           Data.CSV.Conduit
import           Data.Default
import qualified Data.HashMap.Strict  as M
import           Data.Hashable
import           Data.IORef           (IORef, atomicModifyIORef, newIORef, readIORef)
import qualified Data.Map             as Map
import           Data.Pool
import qualified Data.Text            as T
import qualified Data.Text.Encoding   as T
import           Database.Redis.Redis as R
import           Network.HostName
-------------------------------------------------------------------------------
import           Dyna.CVarFormat
import           Dyna.Common
import qualified Instrument.Sampler   as S
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
createInstrumentPool (host, port, rdb) =
  createPool cr R.disconnect 2 300 1
  where
    cr = do
      r <- R.connect host port
      R.select r rdb
      return r


-- Map of user-defined samplers.
type Samplers = M.HashMap T.Text S.Sampler



data Instrument = I {
      threadId :: !ThreadId
    , hostName :: HostName
    , samplers :: !(IORef Samplers)
    , redis :: Pool Redis
    , redisDB :: Int
    }

data SubmissionPacket = SP {
      spTimeStamp :: !Double
    , spHostName :: !HostName
    , spName :: !T.Text
    , spVals :: [Double]
    }


-------------------------------------------------------------------------------
data Aggregated = Aggregated {
      aggTS :: Double
    , aggName :: T.Text
    , aggStats :: Stats
    } deriving (Eq,Show)

instance Default Aggregated where
    def = Aggregated 0 "" def

-------------------------------------------------------------------------------
aggToCSV Aggregated{..} = els
  where
    Stats{..} = aggStats
    els :: MapRow T.Text
    els = Map.fromList $
      [ ("mean", formatNum (FDecimal 6) smean)
      , ("count", showT scount)
      , ("max", formatNum (FDecimal 6) smax)
      , ("min", formatNum (FDecimal 6) smin)
      , ("srange", formatNum (FDecimal 6) srange)
      , ("stdDev", formatNum (FDecimal 6) sstdev)
      , ("metric", aggName)
      , ("timestamp", formatNum FInt aggTS)
      , ("sum", formatNum (FDecimal 6) ssum)
      , ("skewness", formatNum (FDecimal 6) sskewness)
      , ("kurtosis", formatNum (FDecimal 6) skurtosis)
      ] ++ qs
    qs = map mkQ $ M.toList squantiles
    mkQ (k,v) = (T.concat ["quantile_", showT k], formatNum (FDecimal 6) v)


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
    , squantiles :: M.HashMap Int Double
    } deriving (Eq, Show)


instance Default Stats where
    def = Stats 0 0 0 0 0 0 0 0 0 (M.fromList $ map mkQ [1..9])
      where
        mkQ i = (i, 0)


instance (ToJSON a, ToJSON b) => ToJSON (M.HashMap a b) where
    toJSON = toJSON . M.toList


instance (FromJSON a, FromJSON b, Eq a, Hashable a) => FromJSON (M.HashMap a b) where
    parseJSON = fmap M.fromList . parseJSON



$(deriveJSON (drop 3) ''Aggregated)
$(deriveJSON id ''Stats)
$(deriveJSON (drop 2) ''SubmissionPacket)

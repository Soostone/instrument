{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

-- |
-- Module      : Instrument.Measurement
-- Copyright   : (c) 2009, 2010 Bryan O'Sullivan
--               (c) 2012, Ozgun Ataman
--
-- License     : BSD-style

module Instrument.Measurement
    (
      getTime
    , time
    , time_
    , timeEx
    ) where

-------------------------------------------------------------------------------
import           Control.Monad.IO.Class
import           Data.Time.Clock.POSIX  (getPOSIXTime)
import           Control.Exception (SomeException)
import           Control.Exception.Safe (MonadCatch, tryAny)
-------------------------------------------------------------------------------


-- | Measure how long action took, in seconds along with its result
time :: MonadIO m =>  m a -> m (Double, a)
time act = do
  start <- liftIO getTime
  !result <- act
  end <- liftIO getTime
  let !delta = end - start
  return (delta, result)

-- | Measure how long action took, even if they fail
timeEx :: (MonadCatch m, MonadIO m) => m a -> m (Double, Either SomeException a)
timeEx act = do
  start <- liftIO getTime
  !result <- tryAny act
  end <- liftIO getTime
  let !delta = end - start
  return (delta, result)

-- | Just measure how long action takes, discard its result
time_ :: MonadIO m => m a -> m Double
time_  = fmap fst . time


-------------------------------------------------------------------------------
getTime :: IO Double
getTime = realToFrac `fmap` getPOSIXTime

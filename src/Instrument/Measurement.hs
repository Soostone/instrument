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
    ) where

import           Control.Monad          (when)
import           Control.Monad.IO.Class
import           Data.Time.Clock.POSIX  (getPOSIXTime)
import           Text.Printf            (printf)

-- | Measure how long action took, in seconds along with its result
time :: MonadIO m =>  m a -> m (Double, a)
time act = do
  start <- liftIO getTime
  !result <- act
  end <- liftIO getTime
  let !delta = end - start
  return (delta, result)

-- | Just measure how long action takes, discard its result
time_ :: MonadIO m => m a -> m Double
time_ act = do
  start <- liftIO getTime
  _ <- act
  end <- liftIO getTime
  return $! end - start


-------------------------------------------------------------------------------
getTime :: IO Double
getTime = realToFrac `fmap` getPOSIXTime

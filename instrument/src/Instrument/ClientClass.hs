{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}

-----------------------------------------------------------------------------

----------------------------------------------------------------------------

-- |
-- Module      :  Instrument.ClientClass
-- Copyright   :  Soostone Inc
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  experimental
--
-- This module mimics the functionality of Instrument.Client but
-- instead exposes a typeclass facilitated interface. Once you define
-- the typeclass for your application's main monad, you can call all
-- the mesaurement functions directly.
module Instrument.ClientClass
  ( I.Instrument,
    I.initInstrument,
    HasInstrument (..),
    sampleI,
    timeI,
    countI,
    incrementI,
  )
where

-------------------------------------------------------------------------------
import Control.Monad.IO.Class
import Control.Monad.Reader
-------------------------------------------------------------------------------
import qualified Instrument.Client as I
import Instrument.Types

-------------------------------------------------------------------------------

class HasInstrument m where
  getInstrument :: m I.Instrument

instance (Monad m) => HasInstrument (ReaderT I.Instrument m) where
  getInstrument = ask

-- | Run a monadic action while measuring its runtime
timeI ::
  (MonadIO m, HasInstrument m) =>
  MetricName ->
  HostDimensionPolicy ->
  Dimensions ->
  m a ->
  m a
timeI name hostDimPolicy dims act = do
  i <- getInstrument
  I.timeI name hostDimPolicy dims i act

-- | Record a measurement sample
sampleI ::
  (MonadIO m, HasInstrument m) =>
  MetricName ->
  HostDimensionPolicy ->
  Dimensions ->
  Double ->
  m ()
sampleI name hostDimPolicy dims val =
  I.sampleI name hostDimPolicy dims val =<< getInstrument

-------------------------------------------------------------------------------
incrementI ::
  ( MonadIO m,
    HasInstrument m
  ) =>
  MetricName ->
  HostDimensionPolicy ->
  Dimensions ->
  m ()
incrementI m hostDimPolicy dims =
  I.incrementI m hostDimPolicy dims =<< getInstrument

-------------------------------------------------------------------------------
countI ::
  ( MonadIO m,
    HasInstrument m
  ) =>
  MetricName ->
  HostDimensionPolicy ->
  Dimensions ->
  Int ->
  m ()
countI m hostDimPolicy dims v =
  I.countI m hostDimPolicy dims v =<< getInstrument

{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Instrument.ClientClass
    ( I.Instrument
    , I.initInstrument
    , HasInstrument (..)
    , sampleI
    , timeI
    , countI
    , incrementI
    ) where


-------------------------------------------------------------------------------
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import qualified Data.Text              as T
-------------------------------------------------------------------------------
import qualified Instrument.Client      as I
-------------------------------------------------------------------------------


class HasInstrument m where
  getInstrument :: m I.Instrument

instance (MonadReader I.Instrument m) => HasInstrument m where
  getInstrument = ask


-- | Run a monadic action while measuring its runtime
timeI :: (MonadIO m, HasInstrument m)
     => String
     -> m a
     -> m a
timeI name act = do
  i <- getInstrument
  I.timeI name i act


-- | Record a measurement sample
sampleI :: (MonadIO m, HasInstrument m )
       => String
       -> Double
       -> m ()
sampleI name val = I.sampleI name val =<< getInstrument


-------------------------------------------------------------------------------
incrementI :: (MonadIO m, HasInstrument m) => String -> m ()
incrementI m = I.incrementI m =<< getInstrument


-------------------------------------------------------------------------------
countI :: (MonadIO m, HasInstrument m) => String -> Int -> m ()
countI m v = I.countI m v =<< getInstrument


{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Instrument.ClientClass
    ( I.Instrument
    , I.initInstrument
    , HasInstrument (..)
    , sample
    , time
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
time :: (MonadIO m, HasInstrument m)
     => T.Text
     -> m a
     -> m a
time name act = do
  i <- getInstrument
  I.time name i act


-- | Record a measurement sample
sample :: (MonadIO m, HasInstrument m )
       => T.Text
       -> Double
       -> m ()
sample name val = I.sample name val =<< getInstrument

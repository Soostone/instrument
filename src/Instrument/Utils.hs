{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}

module Instrument.Utils
    ( formatDecimal
    , formatInt
    , showT
    ) where


-------------------------------------------------------------------------------
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Numeric
-------------------------------------------------------------------------------



-------------------------------------------------------------------------------
showT :: Show a => a -> Text
showT = T.pack . show


-------------------------------------------------------------------------------
formatInt :: RealFrac a => a -> Text
formatInt i = showT (floor i)


-------------------------------------------------------------------------------
formatDecimal
    :: RealFloat a
    => Int
    -- ^ Digits after the point
    -> Bool
    -- ^ Add thousands sep?
    -> a
    -- ^ Nmber
    -> Text
formatDecimal n th i =
    let res = T.pack . showFFloat (Just n) i $ ""
    in if th then addThousands res else res



-------------------------------------------------------------------------------
addThousands :: Text -> Text
addThousands t = T.concat [n', dec]
    where
      (n,dec) = T.span (/= '.') t
      n' = T.reverse . T.intercalate "," . T.chunksOf 3 . T.reverse $ n

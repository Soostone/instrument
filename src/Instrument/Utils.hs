{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}

module Instrument.Utils
    ( formatDecimal
    , formatInt
    , showT
    , showBS
    , collect
    , noDots
    ) where


-------------------------------------------------------------------------------
import qualified Data.ByteString.Char8 as B
import qualified Data.Map              as M
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Numeric
-------------------------------------------------------------------------------



-------------------------------------------------------------------------------
collect :: (Ord b)
        => [a]
        -> (a -> b)
        -> (a -> c)
        -> M.Map b [c]
collect as mkKey mkVal = foldr step M.empty as
    where
      step x acc = M.insertWith' (++) (mkKey x) ([mkVal x]) acc


-------------------------------------------------------------------------------
noDots :: Text -> Text
noDots = T.intercalate "_" . T.splitOn "."


-------------------------------------------------------------------------------
showT :: Show a => a -> Text
showT = T.pack . show

showBS :: Show a => a -> B.ByteString
showBS = B.pack . show

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

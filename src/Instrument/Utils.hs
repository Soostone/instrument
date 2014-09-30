{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}

module Instrument.Utils
    ( formatDecimal
    , formatInt
    , showT
    , showBS
    , collect
    , noDots
    , encodeCompress
    , decodeCompress
    ) where


-------------------------------------------------------------------------------
import           Codec.Compression.GZip
import qualified Data.ByteString.Char8  as B
import           Data.ByteString.Lazy   (fromStrict, toStrict)
import qualified Data.Map               as M
import           Data.Serialize
import           Data.Text              (Text)
import qualified Data.Text              as T
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
    -- ^ Number
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


-------------------------------------------------------------------------------
-- | Serialize and compress with GZip in that order
encodeCompress :: Serialize a => a -> B.ByteString
encodeCompress = toStrict . compress . encodeLazy

-------------------------------------------------------------------------------
-- | Decompress from GZip and deserialize in that order
decodeCompress :: Serialize a => B.ByteString -> Either String a
decodeCompress = decodeLazy . decompress . fromStrict

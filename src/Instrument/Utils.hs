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
    , indefinitely
    , seconds
    , milliseconds
    ) where


-------------------------------------------------------------------------------
import           Codec.Compression.GZip
import           Control.Concurrent     (threadDelay)
import           Control.Exception      (SomeException)
import           Control.Monad
import           Control.Monad.Catch    (Handler (..))
import           Control.Retry
import qualified Data.ByteString.Char8  as B
import           Data.ByteString.Lazy   (fromStrict, toStrict)
import qualified Data.Map               as M
import           Data.Serialize
import           Data.Text              (Text)
import qualified Data.Text              as T
import           Numeric
import           System.IO
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
formatInt i = showT ((floor i) :: Int)


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


-------------------------------------------------------------------------------
-- | Run an IO repeatedly with the given delay in microseconds. If
-- there are exceptions in the inner loop, they are logged to stderr,
-- prefixed with the given string context and retried at an exponential
-- backoff capped at 60 seconds between.
indefinitely :: String -> Int -> IO () -> IO ()
indefinitely ctx n = forever . delayed . logAndBackoff ctx
  where
    delayed = (>> threadDelay n)


-------------------------------------------------------------------------------
logAndBackoff :: String -> IO () -> IO ()
logAndBackoff ctx = recovering policy [h] . const
  where
    policy = capDelay (seconds 60) (exponentialBackoff (milliseconds 50))
    h _ = Handler (\e -> logError e >> return True)
    logError :: SomeException -> IO ()
    logError e = hPutStrLn stderr msg
      where
        msg = "Caught exception in " ++ ctx ++ ": " ++ show e ++ ". Retrying..."


-------------------------------------------------------------------------------
-- | Convert seconds to microseconds
seconds :: Int -> Int
seconds = (* milliseconds 1000)


-------------------------------------------------------------------------------
-- | Convert milliseconds to microseconds
milliseconds :: Int -> Int
milliseconds = (* 1000)

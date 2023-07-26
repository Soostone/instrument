{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Instrument.Tests.Counter
  ( tests,
  )
where

import Control.Monad
import Instrument.Counter
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests =
  testGroup
    "Instrument.Counter"
    [ testCase "is zero after initialized" $ do
        c <- newCounter
        val <- readCounter c
        assertEqual "should be zero after initialized" 0 val,
      testProperty "registers arbitrary number of hits: increment" $ \(NonNegative (n :: Integer)) -> ioProperty $ do
        c <- newCounter
        forM_ [1 .. n] (\_ -> increment c)
        val <- readCounter c
        pure $ fromIntegral n === val,
      testProperty "registers arbitrary number of hits: add" $ \(NonNegative (n :: Integer)) -> ioProperty $ do
        c <- newCounter
        add (fromIntegral n) c
        val <- readCounter c
        pure $ fromIntegral n === val,
      testProperty "reset brings back to zero" $ \(NonNegative (n :: Integer)) -> ioProperty $ do
        c <- newCounter
        add (fromIntegral n) c
        val <- resetCounter c
        assertEqual "should match" (fromIntegral n) val

        val <- readCounter c
        pure $ 0 === val,
      testProperty "registers arbitrary number of hits close to rollover" $ \(NonNegative (n :: Integer)) -> ioProperty $ do
        c <- newCounter
        let offset = maxBound - 5
        add offset c
        val <- resetCounter c
        assertEqual "offset should match" (fromIntegral offset) val

        val <- readCounter c
        assertEqual "should be zero after reset" 0 val

        forM_ [1 .. n] (\_ -> increment c)
        val <- readCounter c
        pure $ fromIntegral n === val
    ]

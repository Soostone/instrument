# instrument - Haskell production-grade code instrumentation
[![Build Status](https://travis-ci.org/Soostone/instrument.svg?branch=master)](https://travis-ci.org/Soostone/instrument)


## Purpose

We would like to be able to monitor our production Haskell
applications and have historical data on how many times key functions
get called, how long they take, what kind of variation they display,
etc. This package is an attempt at building the necessary
infrastructure.


## Architecture

### Objectives

1. Be lightweight and fast
1. Don't consume much bandwidth
1. Don't consume much memory
1. Support collecting data from multiple nodes running the same code
1. Support multiple backends

### Components

* The application from which data is captured
* A redis server where intermediate captured data is buffered and
  enqueued for processing
* A stand-alone background worker that crunches the data in the redis
  queue and emits the aggregate results into one of the backends we
  support.

### Overall Workflow

Each application maintains an in-memory buffer (behind a forkIO) that
is limited to 1000 samples per key/counter. Every second this buffer
gets pre-aggregated and results get sent to the central redis server.
The worker application that processes these packets to produce the
final output to be fed to the backend. If there is an outage with the
redis server, instrument will exponentially back up to 60 seconds
between retries indefinitely.

## Backends

### Graphite

Our recommended backend is currently graphite. Please see the
examples/graphite folder for the required settings and configuration
file contents.

#### Graphite Counting Example

![instrument Graphite Counting Example](examples/graphite/counting-output.png
 "Example Counting Output")


#### Graphite Sampling Example

![instrument Graphite Sampling Example](examples/graphite/sampling-output.png
 "Example Sampling Output")


### CSV

A very simple backend that any application can easily use on the
outset is a CSV file. The results will simply be locally saved in a
CSV file by the background worker application.


## Example Usage

~~~~~~ {haskell}

import Control.Concurrent
import Database.Redis
import Instrument.Client
import Instrument.Worker

main = do
  forkIO worker
  myApp
  threadDelay 20000000 -- let's wait 20 secs before quitting

-- | Aggregate stats every 10 seconds and output into a simple CSV file.
worker = initWorkerCSV redisInfo "instrument.csv" 10


-- | Our client application
myApp = do
  let cfg = ICfg { redisQueueBound = Just 1000000} -- or def for no bounding
  inst <- initInstrument redisInfo cfg
  timeI "someFunctionCall" inst $ myFunction


-- The default local Redis server
redisInfo = defaultConnectInfo

-- Some function we'll be instrumenting
myFunction = threadDelay 1200 >> print "Hello"

~~~~~~

## Quirks and Limitations

The redis queue bounding functionality drops recent items first, which
effectively means if the queue gets too big it will stop accepting new
data. This way when there's an actual problem, the data will holes in
the data where the problem actually occurred, rather than just having
a fixed window.

The redis queue feature itself uses gzip compression on its data as of
0.2.0.0. If you are using a previous version, you should purge your
instrumentation keys in redis before upgrading.

## TODO

* Go through the design refactor/cleanup various bits.
* Have a better default main entry point for the backend worker
  application.
* Can we emit key/value pairs? How would we display them?
* Sampling support instead of capping collected samples at 1000?
* Use of constant-space, running stats? (Might allow for lossless sampling)

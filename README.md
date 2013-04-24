# instrument - Haskell production-grade code instrumentation


## Purpose

We would like to be able to monitor our production Haskell
applications and have historical data on how many times key functions
get called, how long they take, what kind of variation they display,
etc. This package is an attempt at building the necessary
infrastructure.


## Architecture

### Components

* The application from which data is captured
* A redis server where intermediate captured data is buffered and
  enqueued for processing
* A stand-alone background worker that crunches the data in the redis
  queue and emits the aggregate results into one of the backends we
  support.
  
## Backends

### Graphite

Our recommended backend is currently graphite. Please see the
examples/graphite folder for the required settings and configuration
file contents.

### CSV

A very simple backend that any application can easily use on the
outset is a CSV file. The results will simply be locally saved in a
CSV file by the background worker application.


## TODO

* Go through the design refactor/cleanup various bits.
* Have a better default main entry point for the backend worker
  application.
* Can we emit key/value pairs? How would we display them?
* Sampling support instead of capping collected samples at 1000?
* Use of constant-space, running stats? (Might allow for lossless sampling)



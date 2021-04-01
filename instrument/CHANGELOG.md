# 0.6.0.0
  - Repeatedly call spop rather than spopn for broader redis version
    compatibility. We're making this a breaking version change since
    it might have slightly different performance characteristics.
  - Loosen dependencies
  - Add `timeExI` for a timer that can respond to exceptions and
    `timeI'` which can take the result of the action and emit
    different metrics or suppress metric emission.

# 0.5.0.0
Features:
  - Previously, instrument workers were running the `KEYS` redis
    command at each loop to discover packets. This has O(N) complexity
    where N is the entire keyspace of the database and generally isn't
    safe to use with regularity. In this version, packet keys are also
    transactionally saved to a set which the worker processes, thus
    avoiding having to run `KEYS`.

    *Migration*
    If all of your metric names get written to with any regularity, no
    action is needed as the next time a metric is written, it will
    show up in the keys set and be processed as normal. If for some
    reason you have a significant number of metrics that are
    infrequently or never written to, those keys may become
    unreachable and require manual addition to the key
    set. `Instrument.Client` exports `packetsKey`. You can write a
    migration script that finds all keys prefixed with `_sq_` and
    `SADD` them to `packetsKey`.

# 0.4.0.0

Features:
  - Add dimensions support.
  - Move hostname tracking to dimensions and make it opt-in at the use
    site level.

# 0.3.0.0

Features:
  - Add exponential backoff retries to worker and client code. Errors
    will be logged to stderr and the code will retry indefinitely.

# 0.2.0.0

Features:
  - Add optional queue bounding for redis to prevent overfilling redis
    if its queues are not being emptied properly.
  - Added GZip compression to redis storage to save memory.

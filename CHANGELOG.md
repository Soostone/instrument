# 0.3.0.0

Features:
  - Add exponential backoff retries to worker and client code. Errors
    will be logged to stderr and the code will retry indefinitely.

# 0.2.0.0

Features:
  - Add optional queue bounding for redis to prevent overfilling redis
    if its queues are not being emptied properly.
  - Added GZip compression to redis storage to save memory.

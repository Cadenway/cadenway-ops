---
name: cw-tech-redis
description: "Implement or review Redis-backed rate limiting, presence, caching, or deployment in Cadenway."
---

# Redis for Cadenway

Read the owning repository's boundaries and existing Redis configuration before changing behavior. Gateway rate limits and realtime presence have different ownership; keep keys scoped, expirations explicit where required, and operations safe across instances. Do not treat Redis as a service's primary database or rely on in-process state for cross-instance behavior. Use targeted integration checks with disposable Redis where available.

Consult the official documentation for the version actually used: https://redis.io/docs/latest/.

---
date: 2026-09-17
issue: 1372
impact: patch
title: Hand the verified public npm cache to the compatibility sandbox
---

`secretless-runtime-public-cache` content reaches the runtime-resolved
compatibility lane again: the sandbox is given a disposable copy of the run's
own verified `_cacache/content-v2` at the npm cache path the consumer reads,
so offline installs from the verified public blobs work inside the sandbox.

Isolating the lowercase `npm_config_cache` name (#1254) closed a real ambient
config leak, and also left the sandbox with an empty `/dev/shm/npm-cache`
tmpfs that nothing populated, so consumers installing offline from the
verified blobs failed — `Verjson/verjson-cli` reported
`OFFLINE_PUBLIC_CACHE_MISSING`. That isolation stays closed. The content is
now supplied deliberately instead: the source is derived from the
workflow-controlled `RUNTIME_CACHE_DIR`, never from the ambient cache
variables the sandbox exists to mask, and it is validated against the
`RUNNER_TEMP`-derived path for this run and attempt exactly as the population
block validates its own target — a path that does not match is refused rather
than guessed at.

Only `content-v2` is eligible, so no ambient npm config, index, or credential
state crosses the boundary, and the sandbox receives a staged copy rather than
a bind of the job's cache: npm writes into its own cache while the consumer
runs, so a read-only bind fails npm outright, while a writable bind of the
real cache would let consumer code rewrite content the rest of the job trusts.
The copy is bounded by the population block's existing 256 MiB cap and is
removed when the lane finishes. When `secretless-runtime-public-cache` is off
the runtime cache is never created, and the lane starts the sandbox without
the bind rather than failing to start at all.

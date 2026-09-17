---
date: 2026-09-17
id: 20260917T190000Z
title: The compatibility public cache fails closed, and its assertions hold again
impact: patch
---

An independent review of the verified public npm cache handed to the
compatibility sandbox (#1372, landed in #1396) returned after the repository's
automation had already merged it. Six findings are resolved here.

**The fail-open is closed.** `verified_public_cache_source` started the sandbox
with no cache bind — silently reproducing the offline-install failure #1372 set
out to fix — when `RUNTIME_CACHE_DIR` was empty, or when any component of the
runtime cache path was missing. Neither branch could fire from the workflow,
whose `env:` key is an unconditional expression, so the lenient path fired only
on the regression it should have shouted about, or when the population step
relocated the cache under an unchanged key. Both branches are now gated on
`secretless-runtime-public-cache`: a caller that asked for the cache gets a
named failure, a caller that did not still starts the sandbox without one.

**The assertions that vanished are restored.** Nothing tested the compatibility
step's `RUNTIME_CACHE_DIR`, `RUN_ID`, and `RUN_ATTEMPT` `env:` keys — the
harness injected its own values and read only the step's `run` body, so
deleting all three left every case green. They are asserted on both the legacy
and protected runners now. Two new cases had also borrowed the `cold-cache
compatibility consumer` diagnostic label, letting three pre-existing mutation
assertions be satisfied by a different case's output than the one they pin;
each case now carries its own label, pinned explicitly in every mutation child.

**Two smaller defects.** An ambient npm mask covering the public cache bind
would have layered a `--tmpfs` over it and failed open again; that overlap is
now refused beside the existing workspace-overlap guard, before the existence
test that made the old invariant hold only by accident. Staging cleanup ran
with `ignore_errors=True`, so consumer code sealing a staged directory left
residue under `RUNNER_TEMP` that the job-end cleanup does not reach; it is
reported now, naming only the step's own staging path.

The runtime-cache predicate is unchanged but no longer mis-described: it
compares two values built from the same workflow-controlled `env:` block, so it
is a drift check, not validation of untrusted input.

The review also noted that the writable bind gives consumer code unbounded
write access to real runner disk where the prior tmpfs was RAM-capped. That is
dismissed as denial-of-service only on a disposable ephemeral runner, with the
staged input already bounded by the 256 MiB cap on the population step.

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
relocated the cache under an unchanged key. Both branches are now gated on the
condition that populates the cache — `RESTORE_PERSISTED_PUBLIC_CACHE` or
`secretless-runtime-public-cache`, widened below after review found the first
form of this gate too narrow: a caller that asked for the cache gets a
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

Review follow-up. The fail-closed gate was narrower than the condition that
populates the cache. The install step writes the runtime cache when
`SECRETLESS_RUNTIME_PUBLIC_CACHE` is true **or** when
`RESTORE_PERSISTED_PUBLIC_CACHE` — `inputs.cache && inputs.package-manager ==
'npm'` — is, so an ordinary `cache: true` npm caller that leaves
`secretless-runtime-public-cache` off had its cache populated and bound while
the resolver still read the request as absent and returned a silent `None`.
Verjson/.github#1372 was intact for that caller. The compatibility step now
carries `RESTORE_PERSISTED_PUBLIC_CACHE` and the gate reads both keys, so a
lost or relocated runtime cache fails closed for either population path; a
caller with neither set still starts the sandbox with no cache bind, which
remains the supported no-cache configuration.

The ambient-mask overlap guard no longer derives its guarded paths by
positional slice. `public_cache_arguments[2::3]` held only while every element
was exactly a `--bind src dst` triple; one argument of different arity
re-indexed the slice onto a source path or a flag, and the guard silently
stopped covering the bind target it exists to protect — the drift its own
comment claimed to prevent. The arguments are now walked by a flag-arity table
that guards every mountpoint they create, and an unrecognized or truncated
argument fails closed. Both behaviors are exercised directly: a differently
shaped argument list must not move the guard, and a `cache: true` npm caller
whose runtime cache is absent must fail closed rather than start bare.

The generated set moved together: `node-ci-protected.yml`, the
`LEGACY_SHA256` pin, and the pre-ADR-0178 conformance counter-example. That
last fixture had no generator, so bringing it current meant bisecting the YAML
fold width it had been dumped at; `scripts/gen-conformance-regression-fixture.py`
now owns those round-trip parameters. It reproduces the previously committed
fixture byte for byte from the pre-change contract, and the existing
conformance assertion remains the check — no new validation was enabled.

Review also found the new fixture generator splitting on its body marker without
checking the marker was there. `str.split` returns the whole text when the
separator is absent, so the entire fixture became the header and a second full
dump was appended beneath it — and nothing caught it, because the conformance
assertion parses the result and PyYAML keeps the last of duplicate keys. The
fixture doubled in size on each run while every check stayed green. The marker is
now required.

# 0065 — Changelog tooling uses a verified runner cache

- **Date:** 2026-08-07
- **Issue:** [#379](https://github.com/Verjson/.github/issues/379)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md)
- **Category:** Release architecture
- **Status:** Accepted

## Context

ADR 0038 requires consumers to execute changelog tooling from one immutable
contract commit. Generated renderers and contract tests already pin the commit
and the SHA-256 of `scripts/changelog.py`, but a cache miss downloads the engine
from `raw.githubusercontent.com`. A runner with restricted egress therefore
cannot validate or release even when an administrator has safely preloaded the
required tooling.

A conventional writable cache path is not a trust boundary. Another process,
an interrupted write, or an untrusted restored cache can place different bytes
under the right commit-shaped directory. Availability must improve without
turning cache possession into permission to execute code.

## Decision

Generated changelog renderers and contract tests share one stable preload
contract:

```text
VERJSON_CHANGELOG_TOOL_CACHE/<40-hex-contract-commit>/changelog.py
```

When `VERJSON_CHANGELOG_TOOL_CACHE` is unset, the same layout lives under the
existing per-user cache root:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/verjson-changelog/<commit>/changelog.py
```

The generated artifact embeds both the exact contract commit and the SHA-256 of
the engine at that commit. Every explicit override, cache hit, and downloaded
temporary file must match that digest before execution. A writable cache is
therefore an availability mechanism only, never an authority source.

Resolution is:

1. accept `CHANGELOG_CONTRACT_PATH` only when its bytes match the embedded
   digest;
2. otherwise accept the commit-keyed cache entry only after the same check;
3. on a missing or corrupt entry, fetch the immutable raw GitHub path into a
   unique temporary file;
4. verify the download before atomically publishing it into the cache;
5. fail closed without executing resident or downloaded bytes when verification
   or fallback fails.

Restricted-egress errors name the exact expected cache file, digest, and
`VERJSON_CHANGELOG_TOOL_CACHE` value so runner bootstrap can repair availability
without consumer changes. Generated artifacts remain the only adopter surface;
consumers must not vendor or hand-edit the resolution logic.

## Consequences

- A correctly preloaded runner validates, renders, and releases without network
  access.
- Cache misses retain `raw.githubusercontent.com` as the compatibility fallback.
- Corrupt cache entries are never executed and are repaired only from a
  digest-matching fallback response.
- A restricted runner with no valid preload fails with an actionable error.
- Runner-image/bootstrap delivery is separate work; this decision defines the
  contract it must populate.

## 2026-08-08 correction

Issue [#609](https://github.com/Verjson/.github/issues/609) showed that runner
bootstrap had exported the shared `/opt/verjson/changelog-tools` preload path to
ordinary jobs even when that directory was not writable by the runner user. A
cache hit passed and a cold cache failed, making adopter CI runner-dependent.
`node-ci.yml` now exports a job-scoped cache under `runner.temp`. This contract
repository's own adversarial suite instead clears the inherited runner override
so each fixture's isolated `HOME` remains its cache boundary. Digest verification
remains the authority boundary; either path provides availability only, as this
decision requires.

## Rejected alternatives

- **Trust a commit-keyed filename.** The name does not authenticate writable
  bytes.
- **Vendor the engine in every consumer.** Copies drift and violate ADR 0038's
  central contract.
- **Use only the network fallback.** Integrity remains sound but restricted
  egress makes deterministic checks unavailable.
- **Silently execute a corrupt resident copy when fetch fails.** This converts an
  availability incident into unverified code execution.

# 0095 — Bound secretless Node transfer to an exact-attempt offline cache

- **Date:** 2026-08-12
- **Issue:** [Verjson/.github#750](https://github.com/Verjson/.github/issues/750)
- **Category:** package credentials / untrusted PR execution — **sensitive class**
- **Status:** Accepted

## Context

[ADR 0086](../0086-secretless-node-pr-validation/README.md) and its implementing
[PR #681](https://github.com/Verjson/.github/pull/681) separated credentialed
dependency acquisition from repository-controlled build and test execution. The
handoff archived the complete `node_modules` tree for one day. A normal consumer
PR workload retained 56 artifacts totalling 8.67 GB; delayed expiry and storage
accounting then prevented unrelated workflows from uploading artifacts.

The trust boundary remains load-bearing. Package acquisition may use an explicit
token only after exact scope/package allowlists and immutable download URLs pass,
but no lifecycle, build, or test code may run with that token. The affected
consumer also needs a reviewed private worker migration tree, selected native
dependency rebuilds, a repository-specific command order, Postgres with pgvector,
and Redis. Consumer execution must remain credentialless, and neither a concurrent
run nor a rerun attempt may restore another attempt's dependency input.

## Decision

Keep separate acquisition and build jobs. Acquisition continues to run
`npm ci --ignore-scripts` with a host-scoped npm configuration and a fresh
run-attempt cache. After npm verifies the locked downloads, discard
`node_modules` and transfer only `_cacache`, npm's content-addressed package
tarball store. Reject a cache tar larger than 80 MiB before upload and disable
artifact recompression, keeping the complete two-file artifact envelope below an
81 MiB per-attempt quota budget. A clean acquisition of the affected Tequity API
lock produced a 70,000,640-byte cache tar instead of a 503,314,936-byte installed
tree; it is less than half the consumer's observed 155 MB average compressed
`node_modules` artifact while preserving enough headroom for ordinary lockfile
growth.

Bind the handoff manifest to `run_id`, `run_attempt`, the exact
`package-lock.json` SHA-256, the cache tar SHA-256, and its byte length. The build
job downloads the exact run-attempt artifact, revalidates every binding, and runs
`npm ci --offline --ignore-scripts` with package, repository, cloud, and OIDC
credential paths empty. npm rechecks the lockfile integrity while materializing
`node_modules`; secretless mode disables the optional setup-node Actions cache,
and later consumer npm commands use a job-scoped runtime cache removed at
teardown, so no cross-run or cross-attempt cache restore exists.

Generalize package authorization through an exact newline-separated set of npm
scopes (defaulting to `@verjson`) while keeping every locked internal package
individually allowlisted and pinned to its GitHub Packages URL. Non-default scopes
and packages must exactly match protected caller repository policy, so PR input
cannot widen token-readable package access. Permit one optional auxiliary sparse
checkout described by an exact four-field JSON object that must exactly match
protected caller repository policy. A
repository-controlled pin file must repeat the approved repository and name a
lowercase 40-hex commit before the token-bearing checkout can start. The checkout
path is one hidden top-level directory; the sparse path accepts no absolute path,
traversal, backslash, or glob syntax. Only regular files and directories below the
exact sparse content path enter the same bounded tar and manifest. The build job
validates every tar member before extraction and restores only that path;
acquisition teardown removes the entire auxiliary checkout, including Git
metadata.

After credential scrub and offline installation, permit an exact newline-separated
set of locked packages to reach `npm rebuild`, and an optional unique JSON array of
exact `package.json` script names to run in order. A script entry may remove a
bounded set of non-credential environment names for that step, while protected
credential controls cannot be removed. Invoke npm through argument arrays, not a
shell-expanded command. A custom script plan replaces the default
build/typecheck/test/lint commands. Existing conditional database and cache inputs
provide the consumer's Postgres and Redis services without expanding the
credential boundary.

Remove local acquisition and transfer state under `always()`. A fourth job has
`actions: write`, no checkout, no consumer code, and a five-minute bound. It
verifies the artifact ID, exact run-attempt name, and owning workflow-run ID
before deleting that artifact after build success, failure, or cancellation. The
caller must grant `actions: write`; reusable-workflow permission capping otherwise
makes cleanup fail visibly. One-day artifact retention remains a fallback when
GitHub cannot schedule cleanup. Neither API deletion nor expiry is represented as
immediate quota reclamation because GitHub's accounting can lag by 6–12 hours.

## Consequences

- Normal concurrent and rerun storage is the number of live attempts multiplied
  by less than 81 MiB, rather than an unbounded installed tree per attempt.
- A dependency set whose verified npm cache exceeds 80 MiB fails before upload;
  raising the canonical cap requires a new quota decision, not a caller override.
- Install work happens twice, but only the second, offline install precedes
  consumer build and test execution, and neither install runs lifecycle scripts.
- Multi-scope packages, one immutable sparse auxiliary tree, selective rebuilds,
  and a custom command plan are opt-in and fail closed; existing callers retain
  the `@verjson` scope and standard command sequence.
- Approved rebuild and consumer scripts execute repository-controlled code, but
  only in the credentialless build job after the transfer is fully validated.
- Cleanup uses a narrowly scoped repository token in a job that never checks out
  or evaluates PR-controlled content. Build and test do not receive that token.
- A retry uses **Re-run all jobs** so the new attempt reacquires its own cache;
  failed-jobs-only retries cannot consume the deleted prior-attempt input.
- GitHub can still delay physical deletion or quota accounting. The workflow
  bounds what it uploads and requests exact deletion; it does not promise control
  over platform garbage collection.

## Adoption

Consumers pin
`Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>`,
grant caller `actions: write`, and preserve their exact internal-scope and package
allowlists, auxiliary identity, rebuild list, and script plan. If an adoption also
advances generated changelog artifacts, all
`Verjson/.github/scripts/gen-changelog-caller.sh` outputs—workflow, renderer,
contract test, and release caller—must be regenerated at the same immutable SHA.

## Rollback

Callers may disable `secretless-pr` and return to the existing credentialed
single-job route. Restoring full `node_modules` artifacts is not an acceptable
rollback because it reintroduces the quota failure this decision removes.

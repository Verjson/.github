# 0095 — Bound secretless Node transfer to an exact-attempt private cache

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

Keep separate acquisition and build jobs. Under a trusted host-scoped npm
configuration, acquisition populates a fresh run-attempt cache with `npm cache
add` for only the exact validated GitHub Packages download URLs in the lock. Each
private entry must carry SHA-512 integrity; acquisition verifies the corresponding
content-addressed blob, scans it for the package token, and removes npm's cache
index because its redirect keys contain short-lived signed URLs. Transfer only
`_cacache/content-v2` plus the optional auxiliary tree. Reject the actual tar bytes
when larger than 80 MiB before upload and disable artifact recompression, keeping
the complete two-file artifact envelope below an 81 MiB per-attempt quota budget.

**2026-08-12 correction ([#754](https://github.com/Verjson/.github/issues/754)).**
The earlier 70,000,640-byte evidence measured a compressed cache from an older
lock, but the first implementation emitted an uncompressed tar while disabling
artifact recompression. On the current Tequity API lock, the full npm cache held
163,310,428 bytes and its deterministic gzip payload was 152,659,959 bytes, so
compression cannot satisfy the 80 MiB limit. Populating only the 15 unique exact
private URLs produced a 1,331,200-byte `_cacache` tar; after excluding the cache
index, the 15 integrity-addressed blobs produced a 1,249,280-byte transfer tar. A
clean tokenless `npm ci --ignore-scripts --prefer-offline` then installed 1,010
packages: npm consumed private blobs by lock integrity and fetched public registry
packages online. The build rejects a missing or corrupt private blob before npm,
so an unavailable private dependency cannot fall through to an unauthenticated
network request.

Bind the handoff manifest to `run_id`, `run_attempt`, the exact
`package-lock.json` SHA-256, the private-content archive SHA-256, and its byte
length. The build job downloads the exact run-attempt artifact, revalidates every
binding and tar member, and verifies every locked GitHub Packages integrity blob
before invoking `npm ci --ignore-scripts --prefer-offline` with package,
repository, cloud, and OIDC credential paths empty. npm may fetch public registry
packages online while materializing `node_modules`; secretless mode disables the
optional setup-node Actions cache, and later consumer npm commands use a
job-scoped runtime cache removed at teardown, so no cross-run or cross-attempt
cache restore exists.

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

After credential scrub and dependency installation, permit an exact newline-separated
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

**2026-08-15 correction ([#824](https://github.com/Verjson/.github/issues/824)).**
Organization artifact storage reached quota while current and pinned consumers
were using this handoff. The cleanup permission also prevented a pin-only rollout
for compliant callers that grant only `contents: read` and `statuses: read`.
Replace artifact upload, download, and deletion with `actions/cache/save` and
`actions/cache/restore` pinned to the same immutable v6.1.0 commit. The cache key
contains the exact repository-scoped `run_id` and `run_attempt` plus an
acquisition-generated 256-bit nonce that prevents a caller-controlled sibling
job from reserving the key first; restore supplies no prefix and fails on a
missing exact key. Both actions receive the same stable relative path so the
toolkit's path-derived cache version is identical across acquisition and build
runners with different work roots. The manifest, tar validation, 80 MiB
pre-save cap, credential scrub, and job-local `always()` cleanup remain unchanged.
The cache service has a separate per-repository quota and eviction policy, and no
transfer artifact exists on success, failure, or cancellation. Callers no longer
grant `actions: write` for secretless validation.

An empty approved package set remains valid when the lock contains no internal
package. Acquisition creates an empty private content-addressed tree without an
npm request under the package token; the same manifest and exact-lock validation
then bind the empty payload before the credentialless build installs public
dependencies. Non-empty private-package locks retain every exact URL, SHA-512,
allowlist, and content-set check.

## Consequences

- The bounded handoff uses per-repository cache storage and never organization
  artifact storage; exact-attempt entries are eligible for normal cache eviction.
- A dependency set whose verified npm cache exceeds 80 MiB fails before save;
  raising the canonical cap requires a new quota decision, not a caller override.
- Public packages are downloaded only by the credentialless build job. The
  credentialed acquisition job fetches exact private tarballs without installing
  dependencies or running lifecycle scripts; the build install also disables
  lifecycle scripts.
- Multi-scope packages, one immutable sparse auxiliary tree, selective rebuilds,
  and a custom command plan are opt-in and fail closed; existing callers retain
  the `@verjson` scope and standard command sequence.
- Approved rebuild and consumer scripts execute repository-controlled code, but
  only in the credentialless build job after the transfer is fully validated.
- A retry uses **Re-run all jobs** so the new attempt reacquires its own cache;
  failed-jobs-only retries cannot create a missing acquisition entry.
- Unpredictable exact-run cache keys prevent sibling-job prepopulation and
  cross-run or cross-attempt fallback. Cache branch scope is an additional
  platform boundary, not a substitute for manifest checks.

## Adoption

Consumers pin
`Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>`,
preserve their exact internal-scope and package allowlists, auxiliary identity,
rebuild list, and script plan. Every secretless caller grants `packages: read` so
the reusable acquisition job can request it, regardless of the token mapped to
`NODE_AUTH_TOKEN`. If an adoption also
advances generated changelog artifacts, all
`Verjson/.github/scripts/gen-changelog-caller.sh` outputs—workflow, renderer,
contract test, and release caller—must be regenerated at the same immutable SHA.

## Rollback

Callers may disable `secretless-pr` and return to the existing credentialed
single-job route. Restoring full `node_modules` artifacts is not an acceptable
rollback because it reintroduces the quota failure this decision removes.

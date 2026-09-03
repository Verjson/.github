# 0162 — Unify the portable CI engine and forge adapters

- **Date:** 2026-09-03
- **Status:** Accepted
- **Issue:** [#1249](https://github.com/Verjson/.github/issues/1249)
- **Supersedes:** [ADR 0161](../0161-migrate-ci-to-gitlab-with-measured-parity/README.md)

## Context

ADR 0161 established measured, reversible GitHub-to-GitLab workload cutovers and the
trust boundary between untrusted CI, provider control planes, and privileged status
bridges. It deliberately rejected a speculative universal controller. We now have a
broader product requirement: one canonical CI contract must serve every Verjson
repository, external GitHub organizations, and external GitLab installations while
GitHub remains a tested fallback. Maintaining separately versioned engines and forge
adapters would allow schema, execution, or result semantics to drift.

GitHub and GitLab require files in provider-owned locations, but those files need not
contain the implementation. GitLab components can only be consumed directly within one
GitLab instance, so external instances also need a safe way to mirror immutable releases.
GitHub Actions and GitLab jobs issue different OIDC identities and neither forge accepts
the other forge's job identity directly as pipeline-dispatch authority. GitLab Runner
also removed `gitlab-runner exec`; local GitLab fidelity therefore requires a disposable
GitLab service and registered runner rather than the removed command.

## Decision

Create `Verjson/verjson-ci` as one repository and atomic version line for the portable
contract schema, execution engine, CLI, OCI image, GitHub adapter, GitLab adapter,
conformance fixtures, release machinery, and external mirror kit. Mirror its Git object
graph byte-for-byte to the canonical GitLab CE project so the same commit and unprefixed
SemVer tag identify every release surface.

`Verjson/.github` retains GitHub-organization policy, rulesets, and GitHub-specific Apps.
It consumes `verjson-ci`; it does not carry a separately evolving portable engine.

### Repository topology

```text
verjson-ci/
├── packages/
│   ├── schema/                 # versioned portable contract
│   ├── engine/                 # provider-neutral planner and executor
│   ├── cli/                    # local and CI entrypoint
│   └── result-contract/        # normalized result envelope
├── adapters/
│   ├── github/{action,workflow,result-mapper}/
│   └── gitlab/{component,result-mapper}/
├── .github/workflows/          # thin GitHub-required entrypoints
├── templates/                  # thin GitLab Catalog-required entrypoints
├── container/Dockerfile
├── dev/                        # local act and disposable GitLab harness
├── test/{fixtures,contract,adapters,parity,e2e}/
├── infra/gitlab-mirror/        # Terraform provisioning module
├── tools/sync-gitlab-mirror
├── release/
├── verjson-ci.schema.json
└── .gitlab-ci.yml
```

Repositories declare intent through the versioned contract. The engine performs CI.
Provider adapters schedule it and translate its normalized result to native checks.
Platform entrypoints contain no independent validation or release logic.

### Conformance contract

Every adapter invocation records the same candidate commit, schema version, engine and
CLI version, adapter version, OCI digest, scenario identity, command plan, semantic
outcome, and deterministic artifact digests. Provider URLs, run IDs, timestamps, runner
names, and scheduling metadata are explicitly non-semantic and removed before canonical
JSON comparison. Equal green conclusions alone are insufficient.

The required remote matrix builds one candidate OCI image, then runs the same success,
boundary-error, command-failure, timeout, package-manager, monorepo, credential-refusal,
and applicable/non-applicable ShadScan fixtures through real GitHub Actions and real
GitLab CE concurrently. Merge requires both signed result envelopes to reference the
same commit and OCI digest and to compare equal after documented normalization. Injected
failures prove that skipped jobs, forged check names, stale commits, replayed receipts,
and change-authored control-plane configuration cannot authorize success.

### Local developer parity

`pnpm parity:local` builds the engine and image locally and runs a representative matrix
without publishing an OCI candidate. The GitHub leg uses `act`. The GitLab leg starts an
ephemeral local GitLab CE service and a disposable registered GitLab Runner with the
Docker executor, pushes only disposable fixture commits, collects results, and tears the
services down. `gitlab-runner exec` is forbidden because current Runner releases do not
provide it.

Developers can select one scenario or a change-derived subset, but a schema change always
runs at least one successful case, one boundary failure, both adapters, and normalized
result comparison. Local emulation is a fast feedback gate, not release evidence; only
the real cross-forge matrix authorizes merge and release.

### Cross-forge workload identity

Forge runners never hold a PAT or the opposite forge's trigger credential. Both request
short-lived OIDC ID tokens with a dedicated `verjson-ci-conformance` audience and submit
them to a claim-validating conformance coordinator. Authorization binds immutable
repository or project identity, commit, workflow or job identity, pipeline source,
protected-ref state where relevant, audience, expiry, and one-time `jti` replay state.

Candidate mirroring should normally trigger each forge natively. When explicit dispatch
is unavoidable, the coordinator uses a narrowly installed GitHub App to mint a short-lived
installation token. A GitLab trigger credential, if GitLab CE requires one, remains only
inside the coordinator's secret manager, is restricted to the fixture project, rotated,
and cannot read source or artifacts. OIDC authenticates the calling workload to the
coordinator; it is not misrepresented as direct forge-to-forge federation.

The coordinator accepts signed result callbacks and publishes one aggregate parity
verdict. Missing or unavailable forge evidence fails closed; it never becomes success.

### ShadScan capability

ShadScan remains an optional capability. The engine auto-detects supported React
applications with an explicit override, pins one exact CLI version, stores its versioned
JSON report, and enforces a configurable score floor through baseline-and-ratchet
adoption. GitHub issue creation stays outside the portable core. Rendered `--check-ui`
work runs in a separate preview or integration lane because it requires an already-running
target and Chromium. Both adapters must return the same applicable, non-applicable,
score, finding, and threshold semantics.

### Unified release

One immutable tag without a `v` prefix, for example `1.4.2`, identifies the CLI package
and integrity hash, both registry locations of one OCI digest, the GitHub Action and
reusable workflow, the GitLab Catalog component, the schema, adapters, Terraform module,
mirror sync tool, and signed conformance receipts.

A signed release manifest binds the tag and commit to every artifact identity, path,
digest, receipt, and schema version. Releases are dispatched and restart-safe. The
pipeline builds once, passes local controls, mirrors the candidate commit, passes the
complete remote matrix, signs receipts and the manifest, creates and mirrors the tag,
publishes the CLI and identical OCI digest, publishes both forge releases, exercises the
mirror kit against disposable GitLab CE, verifies every endpoint, and only then marks the
manifest `complete`. Partial publication is quarantined and reconciled; a version is never
reused. Consumers adopt only a manifest marked `complete`.

### External GitLab mirror kit

The versioned Terraform module provisions the destination project, protected unprefixed
SemVer tags, catalog settings where supported, least-privilege deploy identity, scheduled
sync, audit output, and optional registry destination. The sync tool fetches only allowed
SemVer tags, verifies the source tag, commit, signed complete manifest, and canonical
ancestry, preserves exact Git objects, refuses tag rewrite or deletion, verifies the
destination after push, optionally copies the OCI artifact by digest, and emits a signed
synchronization receipt. External instances rebuild neither adapters nor engine.

### Rollout

1. Finish and preserve current CLI-family work.
2. Bootstrap the unified repository, schema, result envelope, and signed manifest.
3. Build the provider-neutral engine, CLI, and OCI image.
4. Deliver both thin adapters in the same versioned change.
5. Deliver local `act` plus disposable-GitLab parity and required remote parity.
6. Add the OIDC coordinator contract, negative authorization tests, and signed receipts.
7. Add unchanged ShadScan semantics and prove them through both adapters.
8. Release once, migrate Verjson repositories by stack in coordinated waves, retain
   GitHub as a tested fallback, then publish external adoption and mirror guidance.

Each schema or semantic engine change must update and pass both adapter matrices in the
same pull request. There is no adapter-only compatibility waiver.

## Consequences

- Core and adapters cannot version independently, eliminating supported version drift.
- Local tests remain fast enough for schema work, while real forges retain release
  authority.
- Cross-forge coordination adds a small security-sensitive service whose claim policy,
  credentials, replay store, and audit trail require independent review.
- GitLab consumers on another instance must mirror the component, but receive supported,
  tested automation for doing so without rebuilding it.
- A cross-forge outage can delay ordinary releases and semantic CI changes. Emergency
  policy must be explicit and cannot fabricate parity evidence.
- ADR 0161's workload classes, secret boundaries, measured cutovers, rollback gates, and
  cost accounting remain controlling where this decision does not replace them.

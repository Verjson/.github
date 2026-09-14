# 0182 — Package-backed portable CI adapter

- **Date:** 2026-09-14
- **Status:** Accepted — activation is conditional on a complete signed release
- **Issue:** [#1264](https://github.com/Verjson/.github/issues/1264)

## Context

The organization currently distributes a large GitHub reusable workflow from
`Verjson/.github`. That workflow couples execution, package acquisition,
organization governance, and GitHub-specific identity assumptions. The same CI
contract must support repositories in different organizations and deployments
hosted on GitHub or GitLab.

`Verjson/verjson-ci` now owns the provider-neutral contract schema, engine,
OCI runtime, normalized result, and forge adapters. A portable migration must
not transfer a GitHub credential into GitLab or let an adopter select mutable
runtime or package code. A complete release, image digest, mirror readback,
and real deployment identities are still required before production cutover.

## Decision

`Verjson/.github` publishes a thin GitHub `workflow_call` facade at
`.github/workflows/verjson-ci.yml`. The facade pins the package reusable
workflow to an immutable commit and requires the caller to provide an OCI
image digest from the same complete signed release manifest. It forwards only
provider-neutral contract inputs: profile, image, config path, and scenario.

GitHub callers retain their own repository, workflow, OIDC, and check context.
GitLab callers consume an instance-local mirror of the same complete release
through the GitLab component adapter. GitLab project identity, protected-ref
claims, job credentials, and runner policy remain inside GitLab. No adapter
accepts credentials or identity claims from the other forge.

The existing `node-ci.yml` remains a GitHub compatibility fallback during
shadow/canary comparison. Promotion requires matching success, failure,
timeout, and credential-refusal outcomes with exact source, release, and
image identities. Rollback is a caller-side workflow pin/config restoration.

## Consequences

- One package owns portable execution behavior and its versioned contract.
- `.github` continues to own organization governance and GitHub-specific
  required-check and App policy.
- Different GitHub organizations can call the reviewed facade without a
  `Verjson`-specific credential assumption.
- GitLab installations must mirror and verify the complete release locally.
- Production adoption is deliberately blocked until release-signing identities,
  image publication, and authenticated deployment probe evidence exist.

## References

- [ADR 0162: unified portable CI engine and forge adapters](../0162-unify-portable-ci-engine-and-forge-adapters/README.md)
- [Portable adoption guide](../../verjson-ci-adoption.md)

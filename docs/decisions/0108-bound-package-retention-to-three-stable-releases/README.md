# 0108 — Bound package retention to three stable releases

- **Date:** 2026-08-18
- **Status:** Accepted
- **Issue:** [#889](https://github.com/Verjson/.github/issues/889)
- **Related:** [ADR 0038](../0038-canonical-changelog-contract/README.md), [ADR 0069](../0069-publish-only-node-release-workflow/README.md)
- **Category:** Destructive package lifecycle

## Context

GitHub Packages storage is finite. Retaining every numbered npm release and container
image makes the organization-wide release contract unaffordable, while deleting without
a deterministic inventory risks removing the current release, a rollback target, or an
image whose tags do not mean what the cleanup assumed.

Package-version deletion becomes irreversible after GitHub's restoration window. The
supported install and rollback window therefore must be an explicit product constraint,
not an incidental side effect of storage pressure. Publication and cleanup also have
different success semantics: a cleanup permission or API failure cannot undo a package
that the registry already accepted.

## Decision

After a successful canonical Node or container publication, a separate non-blocking job
invokes the retention implementation from the same immutable `Verjson/.github` contract
commit as the release workflow.

For each released package or image, the implementation inventories every GitHub package
version before making any deletion request. It orders exact stable `major.minor.patch`
versions by semantic version and retains the highest three. It deletes older stable
numbered versions. It does not count or delete prereleases or non-numbered tags.
Untagged image cleanup has a
seven-day grace period and first resolves the complete OCI descriptor graph of all three
retained indexes. A digest reachable from a retained index is protected regardless of
its age or lack of a tag. Only an old, unreachable object that validates as an OCI image
manifest or index is eligible; ambiguous or artifact metadata fails closed.

The inventory fails closed before deletion when the requested release is absent, IDs or
stable versions are duplicated, pagination leaves the configured GitHub API origin, or
a container version mixes a numbered tag with another tag. The workflow uses only
`contents: read` and `packages: write`; Node cleanup uses its repository-scoped
`GITHUB_TOKEN`, while container cleanup reuses the already-required package-admin release
credential.

Cleanup has `continue-on-error` at the job boundary and depends on successful publication.
An unavailable deletion API or insufficient GitHub package administration permission is
visible as a failed cleanup job but cannot retroactively change publication to failure.

## Consequences

- Only the newest three stable numbered versions are supported for install and rollback.
- Older numbered releases and untagged container versions are intentionally destroyed,
  subject to GitHub's time-limited restoration behavior. Fresh untagged objects and all
  platform/provenance manifests reachable from retained indexes remain protected.
- Prereleases and non-numbered container tags do not consume the stable retention slots.
- Ambiguous tagging stops all deletion for the invocation and requires correction rather
  than guessing.
- A cleanup failure may temporarily exceed the storage target, but never misreports an
  already-published release as unpublished.

## Verification

`package_retention_test.py` covers semantic ordering, exact retention, age- and
reference-safe untagged cleanup with a live-shaped multi-architecture index,
multi-target inventory-before-delete, malformed boundaries, duplicate identities, mixed
container tags, and pagination-origin validation. The Node and container release contract
tests prove cleanup runs after publication, has least privilege, uses the pinned canonical
implementation, and cannot fail the publication job.

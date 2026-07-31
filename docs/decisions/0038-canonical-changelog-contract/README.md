# 0038 — Canonical changelog fragments and immutable release snapshots

- **Date:** 2026-07-30
- **Issue:** [Verjson/.github#249](https://github.com/Verjson/.github/issues/249)

## Context

Several repositories authored a shared aggregate or independently allocated
sequential fragment names. Concurrent feature branches then collided on the same
file or silently obscured overlapping ownership. Some fragmented `CHANGELOG/`
directories also mixed unreleased entries with released history, leaving no
single immutable release record.

## Decision

Verjson repositories use `NEXT/` as the sole unreleased store and
`CHANGELOG/<version>.md` as immutable released snapshots. Ordinary changes use
collision-resistant `YYYY-MM-DD-issue-<issue>-<slug>.md` identities and metadata;
legitimate issue-less work uses a timestamp or short UUID. Duplicate identities
are rejected across canonical and temporarily configured legacy locations.

Release automation serializes repository releases, selects and validates
fragments, refuses snapshot overwrite, creates one snapshot while consuming its
fragments in the same commit, and tags that exact commit. `CHANGELOG.md` is
generated only for display, packaging, or publication and is never an authored
feature-pull-request surface.

The canonical contract, schema, tools, and reusable workflows live in this
repository. Consumers own repository-specific adoption. Temporary legacy reads
are allowed only during the tracked #249 migration and never consume legacy
fragments.

## Consequences

- Independent feature branches no longer coordinate a global sequence or edit a
  shared aggregate.
- A duplicate issue identity becomes an explicit ownership/consolidation signal.
- Released history has an immutable, version-addressable source.
- Release callers require contents-write credentials, default-branch execution,
  and the repository-scoped concurrency lock.
- Migration may temporarily read a named legacy location, but it remains visibly
  transitional and is removed after consumers and queued pull requests converge.

## Rollback

Revert the reusable workflow and tooling adoption in consumers, then revert the
implementing pull request. Do not restore shared authored aggregates or overwrite
released snapshots; supersede this ADR if the organization selects a different
durable model.

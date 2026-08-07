# 0066 — Changelog impact governs version bumps

- **Date:** 2026-08-07
- **Issue:** [#378](https://github.com/Verjson/.github/issues/378)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md)
- **Related:** [ADR 0065](../0065-component-scoped-changelog-streams/README.md), [#390](https://github.com/Verjson/.github/issues/390)
- **Category:** Release architecture
- **Status:** Accepted

## Context

ADR 0038 made fragments the source of release notes but left version selection
to each caller. Commit subjects and package-manager conventions are not reliable
release-impact inputs, and duplicating bump logic in consumer workflows would
let repositories disagree about the same canonical metadata.

ADR 0065 added independently selected component streams. Impact therefore has
to be evaluated after fragment and component selection: a breaking Python
fragment must not force a major release of an unrelated Node stream.

## Decision

A canonical fragment may declare exactly one release impact:

```yaml
impact: minor
```

The accepted values are `major`, `minor`, and `patch`. Absence explicitly means
`patch`, preserving existing fragments and adopters during migration. The
central `scripts/changelog.py` engine validates the value and computes the
maximum impact among only the fragments selected for the release.

For a version-prefix stream, the previous immutable snapshot with the same
prefix is the baseline. The requested version must equal the exact next SemVer
version on the selected axis:

- major: `v0.4.2` to `v1.0.0`;
- minor: `v0.4.2` to `v0.5.0`;
- patch: `v0.4.2` to `v0.4.3`.

Prefixes such as `v` and `python-v` identify independent streams. Ordinary
SemVer axes apply to `0.x`; breaking impact has no special pre-1.0 exception.
The first release in a prefix stream establishes its baseline because there is
no earlier bump to validate.

The engine rejects lower, higher, and skipped bumps before writing a snapshot
or deleting a fragment. Impact remains metadata only and never appears in
rendered release notes. Workflows pass the requested version and selectors to
the engine; consumers must not implement a second parser or bump calculator.

## Consequences

- Release intent is reviewable with the change and enforced identically for
  every adopter.
- Existing fragments without `impact` remain valid and require patch releases.
- Mixed selections use their highest impact, while subset and component
  releases ignore unselected fragments.
- An invalid impact or mismatched version fails closed without mutating release
  state.
- Callers choose version-prefix namespaces, but the engine owns bump validity
  within each namespace.

## Rejected alternatives

- **Infer impact from commit subjects.** Squashes, rebases, and repository
  conventions make them an unstable release contract.
- **Treat breaking `0.x` changes as minor.** This adds a policy exception and
  prevents metadata from expressing the ordinary SemVer major axis.
- **Allow any bump at least as large as required.** Skipped or inflated versions
  would hide mistakes; requiring the exact next version makes intent
  deterministic.
- **Validate in generated workflows.** Duplicate parsers drift and bypass the
  canonical engine, especially across component and subset selection.

# 0183 — Resolve an optional release version in the verified release plan

- **Date:** 2026-09-15
- **Status:** Accepted
- **Issue:** [#1360](https://github.com/Verjson/.github/issues/1360)
- **Category:** release automation GitHub write authority (sensitive class)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md), [ADR 0101](../0101-explicit-release-proposal-autonomy/README.md), [ADR 0122](../0122-split-release-proposal-authority-entrypoints/README.md)

## Context

The generated `Release` workflow has always required an operator to transcribe
an exact SemVer tag, even though the canonical changelog engine already derives
the only version accepted for a selected set of `NEXT/` fragments. That forces a
human to perform version arithmetic and makes the manual release surface harder
to review. It also leaves package, artifact, and snapshot callers with separate
version strings unless the workflow binds them explicitly.

The operator's action remains the release authorization. Leaving the version
blank must not authorize any additional actor, trigger publication on merge, or
allow a proposal-only workflow to escalate into publication. Release selection,
source commit, namespace, and resolved version must be fixed before the
irreversible snapshot push, and a retry must not silently select a different
release.

## Decision

The canonical caller generator emits one optional `workflow_dispatch` version
input with an empty default for `release-node`, `release-artifact`, and
`release-snapshot` callers. The first repository step after checking out the
dispatch commit and the pinned canonical contract invokes the read-only
`changelog.py release-plan` command exactly once for the selected component,
fragments, and prefix.

`release-plan` returns a read-only plan containing the canonical selection
digest, selected fragment names, previous release, highest selected impact,
resolved version, rationale, and released-form notes. A blank version derives
the next version from the selected stream. An explicit version is validated by
the same release bump rule, including the explicit baseline required for a
namespace with no previous snapshot. An empty selection is a successful no-op
plan and produces no version to release. A bootstrap namespace therefore still
requires an explicit version; the workflow never invents an initial baseline.

The generated verify job writes the plan to its step summary and exposes only
validated `selected`, `version`, `package-version`, and `selection-digest`
outputs. Every later job consumes those outputs. Snapshot, package metadata,
verification, artifact builds, and publication are gated on `selected`; the
snapshot and publication continue to use the existing release App boundary,
default-branch admission, exact-head and selection-receipt checks, immutable
contract pins, and serialized retry behavior. The caller has no new permission,
trigger, secret, or proposal-to-dispatch path.

## Consequences

- An operator can authorize one manual Release action without inspecting every
  fragment or transcribing version arithmetic; the summary makes the declared
  impact and exact release notes reviewable.
- Explicit-version dispatch remains compatible and is subject to the same
  namespace and impact enforcement as the mutating release engine.
- Empty component streams are visible successful no-ops and cannot consume a
  fragment, create a tag, write a snapshot, build an artifact, or publish.
- Retries reuse the immutable dispatch source and the resolved plan output; an
  existing snapshot is resumed only for the same resolved tag and verified
  release state.
- Existing adopters must regenerate their caller from this immutable contract
  before they receive the optional input and summary behavior. Hand-edited
  release workflows remain non-conforming.

## Verification

The changelog contract tests cover patch, minor, and major precedence, selected
subsets, component streams, prefixes, explicit bootstrap versions, malformed or
mismatched versions, empty selections, receipt and head races, snapshot/tag
collisions, retries, and the generated caller's unchanged permissions and
trigger surface. The generated release caller contract test also executes the
blank-version plan and its operator summary. The exact pinned `release` command
is exercised in a clean disposable checkout without pushing.

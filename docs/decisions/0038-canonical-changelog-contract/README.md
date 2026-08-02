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

## Amendment (2026-08-01) — the write requirement belongs in the workflow (#295)

"Release callers require contents-write credentials" was recorded above but never
expressed in `changelog-release.yml`, which declared a workflow-level
`contents: read` and no job override. A called workflow's `permissions` block is
the cap, not the caller's, so a caller granting `contents: write` and passing
`push_token: ${{ secrets.GITHUB_TOKEN }}` still handed the job a read-only token.
Every consumer release therefore generated its snapshot, verified its exact tag,
and then died on the final atomic push with `remote: Write access to repository
not granted` / HTTP 403 — leaving no tag, release or package. Evidence:
[verjson-identity-contracts run 30724326491](https://github.com/Verjson/verjson-identity-contracts/actions/runs/30724326491),
tracked downstream as Verjson/verjson-identity-contracts#24.

The `release` job now declares `contents: write` while the workflow-level default
stays `contents: read`. This narrows nothing and widens nothing at the caller: a
caller that withholds `contents: write` still yields a read-only token, because
the caller's grant remains the outer cap. `scripts/changelog-release-permissions.test.sh`
holds the shape — the grant must be scoped to the pushing job, and the
workflow-level default must stay a bare `contents: read`.

Consumers pinned to a pre-fix revision must re-pin both the `uses:` ref and
`contract_ref` before re-dispatching a release.

## Amendment (2026-08-02) — the contract test is generated too (#309)

Adoption was defined above as two generated files plus "a repository-local test
asserting pin agreement". That last clause was the one hand-written surface left,
and it is the only adopter file that encodes assumptions about repository
*state*. Six repositories independently wrote a test that asserted a
**pre-release** tree: named fragment titles greped out of the rendered log,
released entries pinned by SHA-256, `[ ! -e CHANGELOG.md ]`, and
`[ -z "$(render-released)" ]`.

Every one of those is false the moment this contract works as intended. `release`
consumes `NEXT/`, writes `CHANGELOG/<version>.md`, and generates `CHANGELOG.md`.
Worse, adopters wire the suite into `npm test`, which release workflows run in
the publish job — so the first dispatched release pushes its tag, then aborts
before publishing, leaving an orphaned tag, nothing published, and `main` red
thereafter. The migration could not have caught this from a pull request,
because no consumer had yet exercised a release.

`scripts/gen-changelog-caller.sh contract-test <sha>` therefore emits the test as
a third generated file. It derives every content assertion from the tree instead
of naming anything, guards the render block (`render-next` exits non-zero on an
emptied `NEXT/`), asserts `CHANGELOG.md` equals `render-released` output rather
than asserting its absence, and tolerates an adopter with no `release.yml`.
`scripts/ci-gate/changelog-caller-contract.test.sh` builds a fixture adopter and
requires the emitted suite to exit 0 **both before and after a real release** —
the assertion that distinguishes this shape from the one it replaces.

Two invariants that were previously only convention are now enforced by the
generated suite, and adopters may need a cleanup commit alongside regeneration:
a stray `.releaserc.json` (which reintroduces release-on-merge outside this
contract) and a root `NEXT.md` still carrying `##` entries (a second, invisible
running log) both fail it.

Consumers on a hand-written contract test must regenerate rather than patch it.

## Rollback

Revert the reusable workflow and tooling adoption in consumers, then revert the
implementing pull request. Do not restore shared authored aggregates or overwrite
released snapshots; supersede this ADR if the organization selects a different
durable model.

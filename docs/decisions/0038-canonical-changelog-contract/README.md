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

## Amendment (2026-08-02) — the contract test is part of the contract (#309, #304)

"The canonical contract, schema, tools, and reusable workflows live in this
repository" left the adoption *test* on the consumer side of the line. In
practice no consumer wrote one: each copied it from whichever repository had
migrated most recently, so defects propagated sideways across the fleet instead
of being fixed once.

Two shipped that way. The circulating shape asserted the pre-release state —
fragment titles by name, `render-next` succeeding unconditionally, `CHANGELOG.md`
absent, `render-released` empty — every one of which this decision's own release
step destroys by design. It was therefore green until the first release and red
permanently after. In `verjson-cli-cloud` it sat in `npm test`, which the release
workflow runs before `npm publish`, so the first dispatched release aborted after
the snapshot job had already pushed the release commit and tag
([#309](https://github.com/Verjson/.github/issues/309), fixed downstream in
Verjson/verjson-cli-cloud#194). Separately, the copied test set
`CHANGELOG_CONTRACT_PATH` that the generated renderer had stopped reading; it
stayed green only because the default it computed for itself happened to be
byte-identical to the renderer's, so any consumer pointing it at a vendored copy,
CI cache or offline mirror got a green test that had exercised a different
implementation than it asked for
([#304](https://github.com/Verjson/.github/issues/304)).

`scripts/gen-changelog-caller.sh` therefore gains a third mode, `contract-test`,
and the generated test is release-safe by construction: assertions about
repository content are derived from the tree and name no fragment, the unreleased
log block is skipped when a release has emptied `NEXT/`, `CHANGELOG.md` is
asserted **equal** to the contract's rendered release history rather than absent,
and the test cuts a real release against a throwaway fixture so the post-release
invariants are proved rather than assumed.

`CHANGELOG_CONTRACT_PATH` is **not** restored. A variable that redirects
execution to an arbitrary file is the vendored-copy drift this decision exists to
close; the generated test instead resolves the contract through the same emitted
block as the renderer, so both execute the same file by construction. The
interface parity #304 asks for is asserted by execution in
`scripts/ci-gate/changelog-contract-test.test.sh`: the two scripts are observed
resolving one cache directory, and the environment and argv the test hands the
renderer are replayed against the renderer's own acceptance.

Consumers now generate three files from one pin, not two. A consumer holding a
hand-copied `changelog-contract.test.sh` should replace it wholesale rather than
patch it.

## Rollback

Revert the reusable workflow and tooling adoption in consumers, then revert the
implementing pull request. Do not restore shared authored aggregates or overwrite
released snapshots; supersede this ADR if the organization selects a different
durable model.

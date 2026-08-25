# 0132 — Base-authorized pre-contract snapshot moves

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1067](https://github.com/Verjson/.github/issues/1067)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md)
- **Consumer authorization:** [Verjson/agents#13](https://github.com/Verjson/agents/issues/13)

## Context

ADR 0038 makes every `CHANGELOG/<version>.md` snapshot immutable in ordinary pull
requests. That remains the correct default: a pull request must not rewrite, remove,
or reuse published release history. A repository can nevertheless have a historical
file that predates the contract and was incorrectly placed in the immutable namespace
without ever being tagged or released. Verjson/agents#13 is the first reviewed case:
its untagged `CHANGELOG/1.0.0.md` is pre-contract archive material and blocks the first
real `v1.0.0` release.

A consumer-specific exception, a command-line override, or authorization read from the
pull-request head would let the same change authorize its own release-history rewrite.
Matching only a path or version would also allow content substitution, deletion, or a
move to another active changelog namespace.

## Decision

The canonical `check-pr` engine recognizes one narrow migration shape authorized by a
reviewed permit already present on the pull request's base branch. Permits live at
`.github/changelog/pre-contract-migrations.json`, use schema version 1, and contain an
append-only `migrations` list. Each entry binds exactly:

- `source`: one repository-relative `CHANGELOG/<version>.md` path;
- `version`: the exact filename stem, independently stated to make version reuse an
  explicit reviewed fact;
- `sha256`: the lower-case SHA-256 digest of the source bytes on the base revision; and
- `destination`: one safe repository-relative path outside `CHANGELOG/`, `NEXT/`, and
  the generated root `CHANGELOG.md` surface.

The migration pull request must leave the permit file unchanged. `check-pr` reads the
authorizing entry from the base revision, requires the source to be deleted and a
previously absent destination to be added, and compares the base source and head
destination byte-for-byte as well as to the permitted digest. It also requires the same
regular-file Git mode so symlinks, submodules, and executable-bit edits cannot masquerade
as content preservation. The source must not be
present in any tag reachable in the repository. No other `CHANGELOG/` path or generated
aggregate may change in the same pull request.

Permit changes are a separate reviewed pull request. The permit document is strictly
parsed, requires `schema_version` to be the exact JSON integer `1` (not a boolean,
floating-point value, string, or coercible equivalent), rejects unknown fields and
duplicate source or destination identities, and is
append-only once present: prior entries may not be removed or edited. Permits persist
after use as the durable authorization record. Reuse fails naturally because the
authorized source no longer exists and the bound destination already does. The persistent
binding also keeps that destination immutable: a later edit, deletion, or replacement is
rejected because it cannot satisfy the original exact move again.

## Trust boundaries

- The base revision is the authorization boundary. Pull-request-authored permits,
  same-PR widening, and head-only state have no authority.
- The content digest and byte comparison bind authorization to historical content, not
  merely a filename selected by an attacker.
- Exact delete/add state, destination absence, and regular-file mode equality reject
  edits, copies, deletion-only changes, overwrite/merge behavior, symlink substitution,
  mode changes, and ambiguous renames.
- The engine rejects shallow repositories before scanning every local tag for the source
  path. Canonical `check-pr` entrypoints check out the consumer with complete history and
  tags (`fetch-depth: 0`, `fetch-tags: true`), and a registered conformance test binds
  both reusable workflows and every generated caller mode to that prerequisite. Together
  these protect tagged history regardless of tag naming convention.
- The exception is evaluated only for the one permitted move. ADR 0038's ordinary
  immutability, `NEXT/` consumption guard, generated aggregate guard, and release path
  remain unchanged for every other path.

## Consequences

- A migration requires two independently reviewable changes: first append the exact
  permit to the protected base branch, then submit the byte-identical move.
- Consumers pin the immutable canonical contract revision containing this engine; they
  do not copy or weaken the logic locally.
- A wrong digest, malformed permit, missing source, existing destination, tagged source,
  partial move, content change, additional immutable-history change, or permit mutation
  fails closed.
- The persistent permit exposes only reviewed repository paths and a content digest; it
  contains no credential or runtime authority.

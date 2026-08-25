# 0134 — Bind Node release assets to the immutable tag

- **Date:** 2026-08-25
- **Issue:** [#1042](https://github.com/Verjson/.github/issues/1042)
- **Extends:** ADR 0038 (canonical changelog contract), ADR 0062 (verify before tag), ADR 0069 (Node publication consumes the contract version)
- **Category:** release authority and repository contents — **sensitive class**

## Context

The generated `release-node` caller can publish packages and create the matching
GitHub Release, but it has no supported way to attach repository-owned contract
artifacts. An adopter must therefore hand-edit the generated caller or create a
parallel publication workflow. Either route splits release authority and can
upload bytes that were not present in the immutable release tag.

Release assets are attacker-influenced repository data processed by a job with
`contents: write`. A path list can attempt traversal, use a symlink to escape the
checkout, select a directory or special file, collide at GitHub's basename-only
asset namespace, or exhaust runner and API resources. Resume behavior is also a
trust boundary: a retry must converge on the tag's bytes rather than accept or
retain an asset derived from mutable workspace state.

## Decision

`release-node` gains a repeatable, opt-in `--release-asset <path>` generator
argument. It emits a JSON `release-assets` input to the reusable
`node-release.yml` workflow. Omitting the argument emits `[]` and preserves the
existing release behavior.

The reusable workflow validates assets after checking out the exact release tag
and verifying its immutable changelog snapshot. Before any adopter-controlled
lifecycle, preparation, build, or package code runs, it:

- accepts at most 16 normalized repository-relative paths;
- rejects absolute paths, empty or dot segments, traversal, duplicates, and
  duplicate basenames;
- rejects a symlink at the selected path or at any parent component;
- requires a tracked regular Git file with mode `100644` or `100755`;
- caps each Git blob at 100 MiB and the aggregate at 250 MiB; and
- records the exact path, basename, Git blob size, and SHA-256 digest in a
  previous-step output controlled by the Actions runner rather than in mutable
  workspace staging.

All admission validation completes before dependency installation, package
build, npm publication, or GitHub Release mutation. After that untrusted code has
finished, the token-bearing step deletes predictable staging, reconstructs the
exact manifest from `HEAD:<path>`, and compares every mode, byte count, and
SHA-256 digest with the pre-build receipt before contacting the Releases API.
It uploads only paths named by that receipt; directory discovery is never an
authority source.

The existing verify → snapshot → publish ordering is unchanged. For a retry,
the publisher enumerates existing release assets and skips a selected basename
only when GitHub reports the exact `sha256:<digest>` receipt. A same-name
mismatch, missing digest, duplicate remote name, or unreadable release state
fails closed. An absent basename is uploaded without `--clobber`, so an asset
created between inspection and upload makes the job red rather than being
replaced.

The release job retains only its existing `contents: write` and `packages:
write` permissions. No new credential, event, runner class, or publication
authority is introduced.

## Consequences

Asset paths must name committed source artifacts. Generated build outputs remain
the responsibility of the separate `release-artifact` lane; allowing mutable
post-build paths here would destroy the tag-byte binding. Two paths with the same
basename cannot be selected because GitHub Releases flatten uploads into one
asset namespace.

This contract never replaces an existing same-name asset. An older GitHub
Release whose asset digest is unavailable requires owner adjudication rather
than destructive reconciliation. A partial multi-asset upload remains safely
resumable: exact matches are retained and only absent names are attempted.

## Verification

`scripts/ci-gate/release-node-assets.test.sh` executes the real validation and
receipt and terminal delivery blocks against valid tagged files and adversarial malformed JSON,
traversal, symlink, directory, missing, untracked, duplicate, count, per-file
size, and aggregate-size cases. It mutates both the checkout and predictable
staging after admission, proves delivery still uses only receipt-bound tag
bytes, and covers matching retries, mismatches, unverifiable digests, and an
inspection/upload collision race.

The existing generator and reusable-workflow contract tests pin the new input,
the immutable contract ref, the unchanged job dependency order, and the exact
upload reconciliation command.

## Rollback

Revert the implementing pull request. Existing generated callers that omit
assets remain compatible because the reusable input defaults to `[]`; callers
generated with `--release-asset` must repin and regenerate without that option
before the reusable input is removed.

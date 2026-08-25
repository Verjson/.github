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

The reusable workflow validates and stages assets only after checking out the
exact release tag and verifying its immutable changelog snapshot. It:

- accepts at most 16 normalized repository-relative paths;
- rejects absolute paths, empty or dot segments, traversal, duplicates, and
  duplicate basenames;
- rejects a symlink at the selected path or at any parent component;
- requires a tracked regular Git file with mode `100644` or `100755`;
- caps each Git blob at 100 MiB and the aggregate at 250 MiB; and
- reconstructs every staged upload from `HEAD:<path>`, not from mutable working
  tree bytes.

All validation and staging completes before dependency installation, package
build, npm publication, or GitHub Release mutation. The existing
verify → snapshot → publish ordering is unchanged. The publication step creates
or reconciles the release notes first, then uses `gh release upload --clobber`
for the complete prevalidated set. A retry therefore replaces a same-name asset
with the byte-identical tagged blob and repairs partial upload failure without
minting a new tag or consuming another changelog snapshot.

The release job retains only its existing `contents: write` and `packages:
write` permissions. No new credential, event, runner class, or publication
authority is introduced.

## Consequences

Asset paths must name committed source artifacts. Generated build outputs remain
the responsibility of the separate `release-artifact` lane; allowing mutable
post-build paths here would destroy the tag-byte binding. Two paths with the same
basename cannot be selected because GitHub Releases flatten uploads into one
asset namespace.

`--clobber` can expose a brief replacement window if GitHub implements it as a
delete followed by upload. The operation is nevertheless restart-safe: the
canonical bytes are reproducible from the immutable tag, and any failed retry is
red rather than reported as successful. Avoiding that window would require a
new asset name or external transaction mechanism and would no longer reconcile
the requested stable release asset name.

## Verification

`scripts/ci-gate/release-node-assets.test.sh` executes the real validation and
staging block against valid tagged files and adversarial malformed JSON,
traversal, symlink, directory, missing, untracked, duplicate, count, per-file
size, and aggregate-size cases. It also proves staged bytes come from `HEAD` and
that an empty list changes no publication behavior.

The existing generator and reusable-workflow contract tests pin the new input,
the immutable contract ref, the unchanged job dependency order, and the exact
upload reconciliation command.

## Rollback

Revert the implementing pull request. Existing generated callers that omit
assets remain compatible because the reusable input defaults to `[]`; callers
generated with `--release-asset` must repin and regenerate without that option
before the reusable input is removed.

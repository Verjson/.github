# 0069 — Node publication consumes the changelog contract's version

- **Date:** 2026-08-07
- **Issue:** [#455](https://github.com/Verjson/.github/issues/455)
- **Supersedes:** ADR 0060's refusal-only `node-release.yml`
- **Extends:** ADR 0038 (canonical changelog contract), ADR 0062 (verify before tag)
- **Category:** release authority and package credentials — **sensitive class**

## Context

ADR 0038 retired version inference from commit subjects. ADR 0060 then made the
semantic-release-backed `node-release.yml` refuse every call, while adopters moved
to an explicit `workflow_dispatch` that asks `changelog-release.yml` to snapshot
`NEXT/`, create the exact tag, and atomically push both.

That removed release-on-merge but left two defects. First, the canonical Node
publication workflow was unusable, so the generated Node caller duplicated its
own install/build/publish/release job. Second, the changelog contract correctly
rejected `.releaserc.json`, but the only historical implementation of
`node-release.yml` required that file. A publisher could not adopt both central
contracts without either disabling its generated contract test or losing its
publication path.

Review of the generator also found a duplicated `with:` key in its setup-node
step. That is fixed by removing the duplicated publication implementation
entirely; the generated caller now delegates to the reusable publisher.

## Decision

The changelog contract is the sole release authority. The dispatched caller
verifies the source tree, passes its explicit version to `changelog-release.yml`,
and waits for that workflow to create the immutable snapshot and exact tag.

`node-release.yml` is reintroduced only as a consumer of that result:

- `version` is required and must be an exact v-prefixed SemVer.
- `scope` must be a non-empty lowercase npm scope; publication is explicitly
  bound to GitHub Packages rather than advertising an unsupported empty-scope
  public-registry mode;
- `package-dirs` is a validated JSON array so one immutable release can publish
  the complete generated package set without allowing path traversal;
- the remote tag must already exist before checkout;
- checkout is pinned to that tag with persisted credentials disabled;
- the checked-out commit must be exactly tagged and must contain
  `CHANGELOG/<version>.md`;
- `npm version --no-git-tag-version` may align package metadata in the ephemeral
  workspace, but the workflow cannot commit, tag, or push it;
- package publication uses the repository-scoped `GITHUB_TOKEN`; private
  dependency installation uses the separately supplied `NODE_AUTH_TOKEN`;
- package publication records the packed name, version, integrity, and filename;
  on rerun, an immutable registry version is accepted only after authenticated
  metadata proves the same package identity and integrity;
- the GitHub release is created from the immutable snapshot with
  `gh release create --verify-tag`, or updated from that snapshot when it
  already exists for the exact tag;
- success outputs are written only after both publications succeed.

The generated `release-node` caller invokes `node-release.yml` at the same
immutable contract SHA it uses for `changelog-release.yml`, passes the same
version input, preserves `needs: snapshot`, and routes both reusable jobs to the
same runner pool.

## Consequences

There is no `.releaserc.json` or semantic-release path in Node publication.
Merging `main` still publishes nothing. Publication cannot race ahead of the
snapshot because the generated caller expresses the dependency, and the
publisher independently refuses an absent tag or snapshot note.

Publishing npm before creating the GitHub release is a two-system operation and
cannot be atomic. A GitHub release API failure after a successful npm publish
leaves the package published and the job red, but a rerun proves the immutable
registry version has the same package identity and integrity before resuming
release-note publication. Unreadable, unauthorized, or mismatched registry state
fails closed. The tag and changelog snapshot remain the authoritative recovery
data; reversing the order would create the opposite partial state.

## Verification

`scripts/node-release-publish.test.sh` structurally pins the trigger, inputs,
permissions, token separation, existing-tag/snapshot guards, publication
commands, restart-safety guards, and fail-closed outputs, then executes the real
version/tag guard against valid, malformed, and absent tags.

`scripts/ci-gate/release-node-restart.test.sh` executes the reusable workflow's
real npm and GitHub Release reconciliation blocks against success, partial
failure, registry mismatch, authorization failure, and unavailable metadata.

`scripts/ci-gate/changelog-release-caller.test.sh` mutation-tests that the
generated caller pins both reusable workflows to the same immutable contract
commit, preserves the verify → snapshot → publish ordering, passes the exact
version, keeps runner routing aligned, and does not substitute `GITHUB_TOKEN`
for the private dependency credential.

## Rollback

Revert the implementing pull request. That restores ADR 0060's unconditional
refusal. It does not restore release-on-merge, because callers remain explicitly
dispatched and no `.releaserc.json` is reintroduced.

---
date: 2026-08-06
issue: 463
title: "feat(changelog): generate the release caller so it verifies before it tags"
---

`scripts/gen-changelog-caller.sh release-node <sha>` now emits an adopter's `.github/workflows/release.yml`, so the release caller stops being hand-copied from a sibling. The generated shape runs a `verify` job — default-branch guard, exact `v`-prefixed SemVer guard, tag-absence guard, and the repository's full suite — that `snapshot` declares in `needs:`, installs with `NODE_AUTH_TOKEN` while publishing with `GITHUB_TOKEN`, passes an explicit `runner:` so both halves of one release share a pool, and is `workflow_dispatch` only at the pinned contract commit.

The un-generated caller was the last hand-copied adopter file, so all three defects filed against it reached every migrated repository by inheritance: verification ran *after* `changelog-release.yml` had already consumed `NEXT/`, written `CHANGELOG/<version>.md`, tagged and pushed to `main` (#463, #464) — a state neither dispatch recovers, since the same version is refused for the existing tag and a higher one for `release selected no fragments`; `npm ci` authenticated with a repository-scoped `GITHUB_TOKEN` that cannot read a private `@verjson` package owned by another repository (#465); and the snapshot half routed onto a different runner pool from the publish half, queueing silently on hosted runners for a private repository (#465).

Verifying the default branch head is a sound proxy for the not-yet-existing tag because the snapshot commit touches no source, config or dependency — exercised in a disposable checkout, where the pinned `changelog.py release` produced a commit whose diff was exactly `CHANGELOG.md`, `CHANGELOG/<version>.md` and the consumed fragments. The recovery property was demonstrated too: a failing `verify` left no tag, no `CHANGELOG/` and `NEXT/` intact, and the *same* version then released cleanly once the suite was fixed.

The emitted contract test enforces the shape, so an adopter still carrying the copied caller now fails its own suite with the command that fixes it, and an adopter whose suite is not `npm test` commits `scripts/release-verify.sh` rather than editing a generated artifact. Rationale in [ADR 0062](../docs/decisions/0062-release-verifies-before-it-tags/README.md); closes #463, #464, #465.

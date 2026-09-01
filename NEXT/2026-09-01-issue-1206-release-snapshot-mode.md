---
date: 2026-09-01
issue: 1206
impact: minor
title: Add a release-snapshot caller mode for adopters that publish nothing
---

`scripts/gen-changelog-caller.sh` gains `release-snapshot`, a snapshot-only
release caller for an adopter that publishes nothing from its release workflow
but still cuts versioned releases — concretely, a repository whose container
images ship from a separate, independently triggered workflow. It keeps
`release-node`'s immutable `verify` → `snapshot` boundary unchanged and reduces
`publish` to creating or updating the tag's GitHub Release from the immutable
`CHANGELOG/<version>.md`, with no build matrix, no package publication and no
attached artifacts.

Before this mode that adopter had no reachable release caller at all.
`changelog-release.yml` is `workflow_call`, `release-node` reaches `npm publish`
on a package it cannot publish, and `release-artifact` requires at least one
`--build-runner` plus an executable `scripts/release-build.sh` that leaves at
least one file behind. "No release caller at all" is the right shape only for a
repository that cuts no releases; for this one it meant `NEXT/` was never
consumed into `CHANGELOG/<version>.md` while the PR-side contract still reported
fully adopted and green.

The generated `contract-test` mode classifies a caller by its generated
provenance comment before applying a shape, so it now recognizes
`release-snapshot` alongside `release-node` and `release-artifact`. That branch
is deliberately mostly negative: a build job, a private-dependency acquisition
job, a `node-release.yml` delegation, an artifact upload or download, a
`permissions:` block wider than `contents: write`, or any secret beyond the
publish job's own `GITHUB_TOKEN` is a hand edit and is rejected. `--build-runner`,
`--approved-internal-package` and `--release-asset` remain unaccepted by this
mode, so a caller cannot be generated into a half-publishing shape.

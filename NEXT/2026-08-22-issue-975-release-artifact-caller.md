---
date: 2026-08-22
issue: 975
impact: minor
title: Add a release-artifact caller mode for non-npm publications
---

`scripts/gen-changelog-caller.sh release-node` was the only generated release
caller, and it refuses a repository with no scope-owned npm package —
concretely, an Electron desktop app that ships OS installers as GitHub
Release assets instead of publishing to a registry (`Verjson/AiB#211`).

Add `release-artifact`: it keeps `release-node`'s immutable `verify` →
`snapshot` boundary unchanged, and replaces `publish`'s delegation to
`node-release.yml` with a caller-declared `build` matrix (one leg per
`--build-runner <label>`, each running an adopter-owned, fail-closed
`scripts/release-build.sh <version> <output-dir>` hook) followed by a
`publish` job that attaches every runner's artifacts to the tagged commit's
GitHub Release, using the immutable `CHANGELOG/<version>.md` as the notes.

The generated `contract-test` mode now classifies a release caller by its
generated-provenance comment (`release-node` or `release-artifact`) before
applying either shape's checks, so a hand-rolled substitute for either mode
is still rejected — the provenance-based rejection this file exists to
enforce is unchanged, just widened to a second known-good shape.

`docs/changelog/README.md` documents the new mode alongside `release-node`.

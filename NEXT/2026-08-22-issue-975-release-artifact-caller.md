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

**2026-08-22 security follow-up:** an independent review found the generated
`contract-test` checked the `build` job's `needs:`, `if:`, `ref:`, hook
executability, and artifact-upload pin, but never its `permissions:` block or
whether its steps reference a `secrets.*` context. A hand-edited consumer
caller escalating that job's `permissions` from `contents: read` to
`contents: write`, or adding `RELEASE_APP_PRIVATE_KEY` to a build step's
`env:`, passed the generated `scripts/changelog-contract.test.sh` with exit 0
— exactly the divergence this file exists to reject. `RELEASE_APP_PRIVATE_KEY`
mints the App token with main-protection-bypass power (ADR 0099); leaking it
into a job that runs adopter-owned, potentially third-party build tooling on
caller-chosen runners would be a severe privilege escalation. The generator's
own template already emitted the correct least-privilege shape; only the
contract-test's verification of that shape was missing. `contract-test` mode
now asserts the extracted `build_job`'s `permissions:` block is exactly
`contents: read`, and that no `secrets.*` context appears anywhere in the job.

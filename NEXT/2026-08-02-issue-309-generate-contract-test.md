---
date: 2026-08-02
issue: 309
title: Generate the changelog contract test so adopters survive their first release
---

`scripts/gen-changelog-caller.sh` gained a third mode, `contract-test`, so the
adopter suite is generated alongside the workflow and the renderer instead of
being hand-copied.

Every hand-copied version asserted a **pre-release** tree — fragment titles
greped by name, released entries pinned by SHA-256, `CHANGELOG.md` asserted
absent, released history asserted empty. A release consumes `NEXT/` and writes
exactly those files, and adopters wire the suite into `npm test`, which release
workflows run before publishing. The first dispatched release would therefore
push its tag and then die in the publish job.

The generated suite derives every content assertion from the tree, guards the
render block against an emptied `NEXT/`, and asserts `CHANGELOG.md` equals the
rendered released snapshots. `scripts/ci-gate/changelog-caller-contract.test.sh`
now builds a fixture adopter and requires the emitted suite to pass both before
and after a real release.

Two previously-conventional rules are now enforced, so regeneration may need a
cleanup commit: a stray `.releaserc.json`, and a root `NEXT.md` still holding
`##` entries, both fail the generated suite.

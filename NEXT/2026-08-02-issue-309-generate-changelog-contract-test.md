---
date: 2026-08-02
issue: 309
title: Generate the changelog contract test instead of copying it between repositories
---

`scripts/gen-changelog-caller.sh` gains a `contract-test` mode, so the last
hand-copied adoption surface is now generated from the same pin as the workflow
and the renderer. Consumers generate three files, not two
([docs/changelog/README.md](../docs/changelog/README.md)).

The shape in circulation asserted the pre-release state — fragment titles by
name, `render-next` succeeding unconditionally, `CHANGELOG.md` absent — all of
which a release destroys by design, so it was green until the first release and
red permanently after (#309). The generated test derives every repository
assertion from the tree, skips the unreleased log once a release has emptied
`NEXT/`, asserts `CHANGELOG.md` equals the rendered release history rather than
asserting its absence, and cuts a real release against a throwaway fixture.

The generated test no longer sets `CHANGELOG_CONTRACT_PATH`, which the renderer
had stopped reading and which had been passing only because the path it computed
for itself happened to equal the renderer's (#304). Both scripts now resolve the
contract through one emitted block, and
`scripts/ci-gate/changelog-contract-test.test.sh` asserts that parity by
execution rather than by inspection.

Recorded as a dated amendment to
[ADR 0038](../docs/decisions/0038-canonical-changelog-contract/README.md).

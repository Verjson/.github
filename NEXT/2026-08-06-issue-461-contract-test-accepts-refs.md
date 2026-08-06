---
date: 2026-08-06
issue: 461
title: 'fix(changelog): the generated contract test accepts a fragment carrying refs'
---

The contract test emitted by `scripts/gen-changelog-caller.sh contract-test`
rejected an issue-form fragment that also carried `refs:`, reporting `issue
back-link missing from the rendered log` for an entry the engine renders
correctly. Its back-link assertion anchored `_$` immediately after the issue
number, while the renderer appends the `; refs #a, #b` suffix that `refs` exists
to produce. The assertion now matches the shape the engine emits.

`refs:` has been in `KNOWN_KEYS` since #316, so the one combination it was added
for was unusable: validation accepted the fragment, the renderer rendered it, and
the generated test — which adopters wire into `npm test` and which the contract
forbids hand-editing — failed the repository. `Verjson/verjson-upload` hit this
during migration and dropped `refs:` from the affected fragment, losing the
structured linkage.

`scripts/changelog.py` is unchanged; the renderer was right. The fixed assertion
is deliberately not widened into one that cannot fail: the `refs` group is a
spelled-out shape rather than `.*`, the `_$` anchor stays, and the group becomes
**required** once the fragment declares `refs`, so a linkage the render drops
fails the same assertion a missing back-link does.
`scripts/ci-gate/changelog-caller-contract.test.sh` covers one and two `refs`,
and exercises the assertion by corrupting the renderer's output while leaving its
pin and delegation intact. Seven mutants of the assertion die. ADR 0038 carries
the dated amendment.

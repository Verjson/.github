---
date: 2026-08-06
issue: 449
title: 'fix(changelog): preview the released form where adopters actually see it'
---

The release-note preview now runs in `changelog-validate.yml`, so every
repository on the changelog contract sees what a release would freeze into
`CHANGELOG/<version>.md` while its fragments can still be edited.

Until now the preview existed only in `generated-artifacts.yml`, and #437 keeps
every adopter off that workflow — the generator emits a `changelog-validate.yml`
caller and the contract test it generates greps for exactly that string. So the
one review step the contract asks of a fragment author could not be performed by
any repository that follows the contract. Measured on `verjson-authn#154`'s own
check run before the fix: `output.title: null`, summary length 0.

Both workflows now call one implementation, `scripts/changelog-preview.sh`, from
the contract checkout they already make at `contract_ref`. A composite action
cannot serve both callers, because `uses:` cannot be interpolated and a reusable
workflow therefore cannot name an action at the ref its caller pinned. Two
inlined copies is how the preview stayed missing this long, so the shared script
is the point rather than a tidy-up.

The preview stays informational: it runs in its own step, only after the verdict
step passed, and a renderer that fails warns without turning the check red.

Reported by the `verjson-authn` PM while bumping the contract pin.

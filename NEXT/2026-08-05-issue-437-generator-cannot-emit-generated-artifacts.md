---
date: 2026-08-05
issue: 437
title: 'docs(claude): record that the caller generator cannot emit generated-artifacts.yml'
---

Adopters should stay on `changelog-validate.yml` and leave `adr-index` off until
#437 lands.

`gen-changelog-caller.sh` emits only a `changelog-validate.yml` caller, and the
contract test it generates asserts exactly that string, so pointing
`changelog.yml` at the shared `generated-artifacts.yml` makes a repository fail
its own conformance test. `8ee480d` taught the org-side classifier the new shape
but not the generator. Separately, `generated-artifacts.yml` counts an opted-in
check whose generator is absent as a failure, so `adr-index: true` is gated on
adopting `scripts/gen-adr-index.sh`, not on having `docs/decisions/`.

Both were found by the `verjson-observability` PM, who refused to bridge the gap
by hand-editing generated artifacts and reported it upstream instead. That is
the behaviour the contract wants; recording it here so the next adopter is told
before it costs them a red check.

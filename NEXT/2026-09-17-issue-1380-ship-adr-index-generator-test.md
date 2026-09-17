---
date: 2026-09-17
issue: 1380
title: The ADR index generator now ships with the suite that covers it
impact: minor
---

`scripts/gen-changelog-caller.sh` gained an `adr-index-test` mode, so an adopter
that opts into ADR-index checking acquires `scripts/gen-adr-index.test.sh` from
the pin instead of hand-keeping a copy that rots. The mode re-emits the
canonical hub suite, rewriting only its repository-root computation for the
adopter's flat `scripts/` layout and failing closed if that line ever moves.

The generated contract test pins the emitted suite's digest as
`ADR_INDEX_TEST_SHA256` and asserts it inside `validate_adr_generator()`, so the
requirement applies only where `adr-index: true` is already in effect. A
missing suite, or a hand-written one, now fails validation with the exact
acquisition command rather than passing quietly.

The suite is a member of the atomic generated set: regenerate it together with
the workflow caller, renderer, generator, and contract test at one pin.

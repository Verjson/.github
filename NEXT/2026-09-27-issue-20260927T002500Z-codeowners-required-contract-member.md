---
date: 2026-09-27
id: 20260927T002500Z
impact: minor
title: The generated .github/CODEOWNERS is a required member of the adopter contract (#1272)
---
`scripts/gen-changelog-caller.sh contract-test` now pins the digest of the canonical CODEOWNERS bytes (source: `config/codeowners/CODEOWNERS`, embedded in the generator so a pinned generator alone reproduces them), and the generated suite fails closed when `.github/CODEOWNERS` is absent, hand-edited, symlinked, or shadowed by a root or `docs/` `CODEOWNERS`. Adopters regenerating at this SHA must also run `scripts/gen-changelog-caller.sh codeowners "$PIN" > .github/CODEOWNERS`; the adoption command lists say so.

ADR 0210 records the decision: keep `require_code_owner_review` in `main-protection` and make it real through the generated member, rather than drop the rule. It costs the autonomous merge path nothing (the merge Apps bypass the rule) and gives the human path a real reviewer requirement. The meta-suite asserts all four rejections with its no-op-mutation guard.

Fleet operators: the pin-bump runbook must add the `codeowners` step before the first fleet repin at or after this SHA, or every adopter's contract check turns red on the same day.

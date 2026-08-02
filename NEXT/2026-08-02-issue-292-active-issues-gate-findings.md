---
date: 2026-08-02
issue: 292
title: Track the two merge-gate findings from the PR 288 re-review post-mortem
---

`CLAUDE.md`'s Active Issues list loads into every session, so a finding missing from it is
one the next session starts blind to. Two findings from dissecting the failed re-review on
#288 are now listed:

- **#292** — the re-review skip has never fired in this repository. `gh api user` cannot
  resolve an identity under `github.token`, so the gate-identity guard is permanently
  unsatisfied and every head change re-pays for a byte-identical diff. On #288 that cost
  three passes and ~$1.49 to re-review a patch-id already approved 37 minutes earlier.
- **#293** — the `budget_exhausted` probe loops over three variables that all resolve to
  the same `$RUNNER_TEMP` path, so each pass overwrites the last and only the final pass's
  subtype survives. A first-pass `error_max_budget_usd` is erased, and the maintainer gets
  a generic "review could not complete" instead of the budget-exceeded guidance that names
  the cap and the diff size.

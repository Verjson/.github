---
date: 2026-08-07
title: Bridge the re-review label lane, for that label only
issue: 481
---

`ai-review-merge.yml` documents a re-review lane — apply `re-review` and the gate re-runs — and
guards it at `:165`. That lane had never fired: the gate is installed as a required workflow by
the `main-protection` ruleset, which schedules it for `opened`, `synchronize` and `reopened`
only, so its own `labeled` type produces no run. Measured dead on throwaway PR #471 (a probe
workflow's `labeled` run fired; the gate produced none).

`gate-rearm.yml` now subscribes to `labeled` and admits **`re-review` only**, matched in the job
`if:` rather than re-checked inside the step. That placement is the safety property, not a
detail: a name checked later would still start a job — and bill a runner — for every label on
every pull request in the fleet. #479 left `labeled` out for exactly that reason, so the
narrowing is the whole fix and is asserted rather than assumed: a test pins the exact name in
the guard, and pins that `needs-review`, `blocked` and `documentation` do not appear in it.

Retiring the lane was the alternative #481 offered. Bridging won because a documented capability
that silently does nothing is worse than either having it or not having it — it reads as
working, which is how #468 went unnoticed.

**No self-dispatch loop.** The gate consumes `re-review` by removing it, which emits
`unlabeled`, and that arm admits only the terminal-hold spellings. The exclusion predates this
change, so the new arm is a no-op for it. Both halves are pinned: the removal path excludes
`re-review`, *and* the gate is still the actor doing the removing — the loop analysis is only
sound while that holds.

Unaffected: #292 means the re-review *skip* is still dead in production, so a re-review re-pays
for an unchanged diff. This makes the lane fire; it does not make the skip work. #497 (the hold
enumeration versus the normalizer) is also untouched.

Rationale: [2026-08-07 amendment to ADR 0063](docs/decisions/0063-required-workflow-events-are-bridged/README.md).

---
date: 2026-08-05
id: 20260805T213000Z
refs: 426
title: 'ci(changelog): print the released shape in the check job summary'
---

The `changelog` check in `generated-artifacts.yml` now renders
`render-next --as-released` into the job summary, so reviewers see what a
release would publish while the fragments can still be edited. A released
snapshot is immutable, so without this the released form is first seen when it
can no longer be changed.

The preview is informational and never a verdict: it runs after the check has
already decided, its exit status is bound to `preview_rc`, and nothing
verdict-bearing reads it. A consumer pinning an older `contract_ref` — one whose
engine has no `--as-released` — therefore gets a warning and a passing check
rather than a breaking change.

A failed preview is still reported. "No unreleased fragments" and "the renderer
broke" are distinguished, because collapsing them is exactly the fail-open shape
of #399. ADR 0055 is amended to record that this is not the second
verdict-bearing render it refuses.

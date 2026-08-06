---
date: 2026-08-06
issue: 452
title: 'docs(claude): record that a gate finding blocks a PR permanently'
---

Working notes now warn that a pull request the gate has ever faulted cannot
merge on its own, even after the finding is fixed.

`reviewDecision` is computed from the latest review per reviewer, not per
commit, so the bot's `CHANGES_REQUESTED` outlives the commit it was written
against. The re-review turns the `gate` check green without dismissing it, and
the pull request sits at `BLOCKED` with nothing left to fix. Landing #450 needed
a manual review dismissal and `--admin`.

The pointer is here so the next session recognises the state instead of hunting
for a failing check that does not exist. The gate fix is tracked in #452.

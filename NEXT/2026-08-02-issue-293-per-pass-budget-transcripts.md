---
date: 2026-08-02
issue: 293
title: Snapshot each review pass's transcript so a first-pass budget failure is still reported
---

The merge gate's budget probe looped over `EXEC_FILE_1/2/3`, but all three resolved to the
one fixed path `claude-code-action` writes under `$RUNNER_TEMP`. Each pass overwrote the
last, so the loop read the final pass three times and an earlier `error_max_budget_usd` was
gone before it was read. On PR #288 (run 30724025229) pass 1 died at the $0.50 cap and the
step still logged `budget_exhausted=false`, so the maintainer got a generic "review could
not complete" instead of the budget-exceeded message that names the cap, the diff size and
the advice to split the PR. Since the first pass carries the smallest cap, that ordering is
the common one, which left the recovered/blocked branch effectively dormant.

Each pass now snapshots its transcript to `$RUNNER_TEMP/claude-execution-pass-N.json` the
moment it finishes, and `EXEC_FILE_N` reads the snapshot. The snapshot steps are `always()`
+ `continue-on-error` and end in an unconditional `exit 0`, so a failed copy degrades the
message and never the merge decision; each clears its destination first, so a skipped pass
on the persistent pool cannot inherit a stale transcript. `BUDGET_EXHAUSTED` still only
chooses the wording of the no-verdict comment — a run with no verdict is blocked either
way. ADR 0032 is amended with the evidence rather than superseded: it already specified
per-pass transcripts, which is the invariant this restores.

Also closes **#251**, the clean-`main` failure of `budget-exceeded.test.sh` ("recovered
verdict must still approve"). That was a fixture gap, not a production regression: the
submit step runs under `set -u` and embeds `ai-review-run:${GITHUB_RUN_ID}` in the approval
body, and the harness never exported `GITHUB_RUN_ID`, so the approve path died on an
unbound variable before any `gh` call — while the sibling extraction test for the same
block (`review-comment.test.sh`) supplied it and passed throughout. The harness now
supplies the run id and pins it two ways: the marker must reach the approval body, and an
absent run id must still fail closed rather than approve.

`budget-exceeded.test.sh` now resolves `EXEC_FILE_N` and the snapshot destinations from the
workflow itself and replays the passes in job order against the single fixed path, so it
exercises the wiring rather than only the loop. Mutation-verified 10/10, including aliasing
the three `EXEC_FILE` vars back to one path, silencing the copy, pointing every snapshot at
a shared destination, dropping `continue-on-error`, inverting the recovered/blocked branch,
and re-opening the blank-verdict guard.

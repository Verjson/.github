---
date: 2026-08-07
title: Make turn exhaustion visible to the gate's retry-outcome probe
issue: 442
---

The `retry_outcome` probe matched only `error_max_budget_usd`, so a review pass that died on
the 15-turn cap was invisible: `turns_exhausted` did not exist and `budget_exhausted` stayed
`false`. The run surfaced as an unexplained gate failure — the same illegible shape #293 fixed
for the budget, still present for the sibling limit.

The two limits are reported **separately**, not folded together, because their remedies
diverge. A budget failure means the PR is larger than the review budget. A turn failure means
the review ran out of exploration steps at that same size, so raising the budget does nothing;
the blocked message says so explicitly. Conflating them would tell a maintainer to split a PR
whose size was never the problem — the false positive the budget probe already takes care to
avoid.

Four assertions in `scripts/ci-gate/budget-exceeded.test.sh`, covering both polarities and both
directions of non-conflation: recovered turn exhaustion is explained as recovered; unrecovered
is not called recovered; a turn failure does not set `budget_exhausted`; and a budget failure
does not set `turns_exhausted`. The last two exist because the first two alone are satisfiable
by setting both flags on any exhaustion.

Red first, against the unfixed probe:

```
FAIL - #442: recovered turn exhaustion not detected/explained (rc=0 turns=): … budget_exhausted=false
FAIL - #442: unrecovered turn exhaustion mishandled (rc=0 turns=): … budget_exhausted=false
FAIL - #442: budget exhaustion set turns_exhausted (budget=true turns=)
```

Related: #441 is the adjacent defect — a budget- or turn-exhausted pass still emits a
schema-shaped placeholder verdict that the gate accepts, and its `outcome=recovered` notice
then tells the reader the run was reviewed. This change makes the turn limit *legible*; it does
not stop the placeholder from being accepted.

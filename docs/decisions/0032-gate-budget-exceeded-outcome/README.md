# 0032 — Size the merge-gate review budget to the diff, and make budget exhaustion an explicit blocking outcome

- **Date:** 2026-07-29
- **Issues:** Verjson/.github#181
- **Category:** merge gate behaviour (sensitive class)
- **Refines:** ADR 0015 (ai-review retry chain), ADR 0024 (absent checks fail closed)

## Context

`ai-review-merge.yml` gave every non-sensitive PR the same $0.15 first-pass
budget and every sensitive PR $0.50, regardless of diff size. On
`Verjson/verjson-cli-cloud#163` (1,586 changed lines) the cheap pass burned
$0.21 against the $0.15 cap, stopped as `error_max_budget_usd`, and produced no
verdict. The escalation recovered — sonnet-5 finished in 12 turns for $0.70 —
so the ladder from ADR 0015 worked as designed. Three problems remained.

**1. The budget was not keyed to the input.** A large diff exhausts the cheap
tier deterministically, so every big PR pays a full strong-model escalation on
top of a wasted cheap pass. The floor was a constant where the cost driver is a
variable.

**2. The outcome was illegible.** `anthropics/claude-code-action` emits
`error_max_budget_usd` as a *failure-level* annotation even when the step is
`continue-on-error` and a later pass succeeds. On #163 the recovered first pass
left a red annotation next to an unrelated genuine failure (a blocking verdict),
and the run was read as "the gate failed with `error_max_budget_usd`". Nothing
in the run said the exhaustion had been recovered.

**3. Total exhaustion failed *open*, not closed.** The no-verdict guard was

```sh
if ! jq -e '.blocking | type == "boolean"' <<<"$VERDICT"; then   # fail closed
```

When all three passes return no structured output, the step's expression
resolves `VERDICT` to the **empty string**. `jq -e` on empty input produces no
output and exits **0**, so the negation is false, the guard never fires, and the
step falls through to `gh pr review --approve` and exits 0 — green gate, merge
allowed, PR never reviewed. Only a malformed *non-empty* verdict (jq exit 4)
ever reached the fail-closed branch, which is why the existing coverage
(`review-comment.test.sh`, fixture `not-json`) passed throughout. This is the
same fail-open shape recorded in ADR 0024.

## Decision

**Budget is keyed to diff size.** `classify` emits `changed_lines`
(additions + deletions) and raises the first-pass cap for diffs at or above 800
changed lines: $0.15 → $0.60 for the cheap tier, $0.50 → $0.90 for the
sensitive tier. Both large-diff tiers stay strictly under the $1.00 escalation
cap so escalation remains a real step up rather than a lateral move.

**Budget exhaustion is a named outcome, not an annotation.** The gate reads the
per-pass SDK transcripts (`execution_file`) and classifies the run itself. When
a pass was budget-exhausted but a later pass produced a verdict, the run logs
`budget_exhausted=true outcome=recovered` and states that the red annotation is
expected and not the cause. When no pass produced a verdict, the run logs
`outcome=blocked` and the PR comment names the cause — the diff size, the cap
that was hit, and the advice to split the PR — instead of leaving
`error_max_budget_usd` as the only signal.

**Exhaustion blocks; it never merges.** The no-verdict guard now rejects a blank
verdict *before* consulting `jq`. The exhaustion flag chooses only the wording
of the comment: every branch labels the PR `ai-review-inconclusive`, posts an
explanation, and exits non-zero. A missing, unset or unparseable transcript
degrades to the generic no-verdict message and still blocks.

## Consequences

- A large PR gets a first pass that can finish, so the common case stops paying
  for a wasted cheap pass plus a strong-model escalation.
- Worst-case gate spend per run rises from $0.15/$0.50 + escalations to
  $0.60/$0.90 + escalations. This is bounded, and only for diffs ≥ 800 changed
  lines.
- A budget-exhausted review is now a red gate with a written explanation and a
  request for human review — the fail-closed behaviour the gate always claimed.
- The 800-line threshold and the $0.60/$0.90 tiers are calibration, not
  principle. They are pinned by `scripts/ci-gate/budget-exceeded.test.sh`, which
  asserts the invariant that matters: a large diff is raised above the cheap
  floor and stays below the escalation cap.
- Splitting an oversized PR remains the cheaper answer than raising the cap
  again; the comment says so.

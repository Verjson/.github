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

### The fix is not live for consumers until the moving tag advances

Closing the empty-verdict fail-open on `main` does not protect cross-org
consumers. Per ADR 0022 they pin `uses: …/ai-review-merge.yml@v1`, and both `v1`
and `v2` still carry the vulnerable guard (`v2` is 9 commits behind `main` at the
time of writing). Until the moving tag is advanced, every consumer repo can still
auto-merge an unreviewed PR when all review passes exhaust without a verdict.

Advancing the tag is therefore part of landing this decision, not follow-up
housekeeping, and it is the step that actually remediates the vulnerability.

## Amendment (2026-08-02, #293) — "per-pass transcripts" was never true

The decision above says the gate "reads the **per-pass** SDK transcripts
(`execution_file`)". It did not. `EXEC_FILE_1/2/3` were wired to
`steps.claude{,_retry,_retry2}.outputs.execution_file`, and
`anthropics/claude-code-action` writes every pass to one fixed path under
`$RUNNER_TEMP`. All three expressions resolved to the same file, each pass
overwrote the last, and the probe's three-iteration loop read the final pass
three times. Any earlier `error_max_budget_usd` was gone before it was read.

Evidence — PR #288, run 30724025229: pass 1 ended `error_max_budget_usd` (11
turns, $0.5045 against the $0.50 cap), passes 2 and 3 ended
`error_max_structured_output_retries`, and the step still logged
`budget_exhausted=false`. The maintainer got "review could not complete" instead
of the budget-exceeded message that names the cap, the diff size and the advice
to split. Because the first pass carries the *smallest* cap, budget failure in
pass 1 is the common ordering, so the recovered/blocked branch was effectively
dormant.

Restored, not changed: each pass now copies its transcript to
`$RUNNER_TEMP/claude-execution-pass-N.json` immediately after that pass runs, and
`EXEC_FILE_N` points at the copy. The snapshot steps are `always()` +
`continue-on-error` and end in an unconditional `exit 0` — a failed copy
degrades the *message* and can never fail the gate, which keeps telemetry on the
reporting side of the line this ADR draws. Each snapshot clears its destination
before copying, so a skipped pass on the persistent self-hosted pool cannot
inherit a stale transcript and invent an exhaustion that did not happen.

**The merge decision is untouched.** `BUDGET_EXHAUSTED` still only selects the
wording of the no-verdict comment; every branch of that guard labels the PR
inconclusive, comments and exits non-zero. `budget-exceeded.test.sh` pins that
end to end for the #288 shape, and the change is mutation-verified (killed,
including aliasing the three `EXEC_FILE` vars back to one path, silencing the
copy, inverting the recovered/blocked branch, and re-opening the blank-verdict
guard).

Also corrected here: the clean-`main` failure of `budget-exceeded.test.sh`
tracked as #251 ("recovered verdict must still approve") was a **fixture** gap,
not a regression of this decision. The submit step runs under `set -u` and embeds
`ai-review-run:${GITHUB_RUN_ID}` in the approval body; the harness never exported
`GITHUB_RUN_ID`, so the approve path died on an unbound variable before reaching
`gh`. The sibling extraction test for the same block
(`review-comment.test.sh`) always supplied it and always passed. The production
behaviour was correct — and correct in the fail-closed direction, since an absent
run id aborts rather than approves, which is now pinned as its own case.


# 0002 — AI merge gate: escalate on budget exhaustion instead of failing

- **Date:** 2026-07-15
- **Issue:** none (raised from a stuck run — `Verjson/github-runner-docker-compose#3`)
- **PR:** Verjson/.github#23
- **Category:** CI merge gate / autonomous merge authority (sensitive-class)

## Context

The org merge gate (`.github/workflows/ai-review-merge.yml`) runs a Claude
review with a hard `--max-budget-usd` cap and `--json-schema`. When the model
exhausts the budget mid-review it returns subtype `error_max_budget_usd` with an
**empty** `structured_output`, and the action then fails the step with
`--json-schema was provided but Claude did not return structured_output`.

Because `ai-merge` requires `needs.ai-review.result == 'success'`, that hard
failure blocks the PR. Observed on `github-runner-docker-compose#3`: a healthy
PR was killed when Haiku hit `$0.15` at **$0.1614 on turn 11**. The budget cap
was doing its job; the defect was treating exhaustion as a review failure rather
than a signal to try harder. The goal was to fix this **without** just raising
the flat cap (which would inflate the cost of every review).

## Decision

Three changes, all preserving the fail-closed property (never auto-merge without
a real verdict):

1. **Graceful handling.** The review step is `continue-on-error: true`; the job
   no longer dies on an empty verdict.
2. **Escalate, don't inflate.** An empty `structured_output` triggers a second
   pass on `claude-sonnet-5` at `$1.00`. It runs **only** when the first pass
   produced no verdict, so the common case stays on the cheap tier. If both
   passes fail, the gate labels the PR `ai-review-inconclusive`, comments an
   explanation, and exits non-zero (no merge, but actionable — not cryptic).
   The escalation is a **fresh** pass, not `--resume`: cross-invocation session
   state is not guaranteed and a resume that errored would strand the exact PR
   we are unblocking. Re-exploration cost is trivial for a rare event.
3. **Reduce exhaustion frequency.** `--max-turns 24 → 15` and a prompt economy
   instruction (read the diff, then only the files a finding depends on; return
   the verdict as soon as it is supportable) cut the agentic wandering that
   drove the per-turn token cost.

## Effective before → current (sensitive hunks)

```diff
       - name: Claude review (merge gate)
         id: claude
+        continue-on-error: true
         uses: anthropics/claude-code-action@v1
         ...
-            --max-turns 24
+            --max-turns 15
             --max-budget-usd ${{ needs.classify.outputs.budget_usd }}
+
+      - name: Escalate review when the first pass ran out of budget or turns
+        id: claude_retry
+        if: steps.claude.outputs.structured_output == ''
+        continue-on-error: true
+        uses: anthropics/claude-code-action@v1
+        with:
+          ...
+          claude_args: |
+            --model claude-sonnet-5
+            --max-turns 30
+            --max-budget-usd 1.00

       - name: Submit deterministic PR review
         env:
-          VERDICT: ${{ steps.claude.outputs.structured_output }}
+          VERDICT: ${{ steps.claude_retry.outputs.structured_output != '' && steps.claude_retry.outputs.structured_output || steps.claude.outputs.structured_output }}
         run: |
           set -euo pipefail
-          jq -e '.blocking | type == "boolean"' <<<"$VERDICT" >/dev/null
+          if ! jq -e '.blocking | type == "boolean"' <<<"$VERDICT" >/dev/null 2>&1; then
+            gh pr edit "$PR_NUMBER" --repo "$TARGET_REPO" --add-label ai-review-inconclusive 2>/dev/null || true
+            gh pr comment "$PR_NUMBER" --repo "$TARGET_REPO" --body "⚠️ Merge gate: review could not complete ..."
+            exit 1
+          fi
```

## Consequences

- Healthy PRs are no longer blocked by the cheap tier's budget; exhaustion
  escalates to a stronger model instead of failing.
- Worst case is two model invocations (bounded); the second is skipped whenever
  the first pass returns a verdict, so steady-state cost is unchanged.
- Fail-closed is preserved: if neither pass produces a verdict the PR is held
  (labelled + explained) and never auto-merged.
- New surface: an `ai-review-inconclusive` label (best-effort; `|| true` if a
  repo lacks it) signals PRs needing a human.

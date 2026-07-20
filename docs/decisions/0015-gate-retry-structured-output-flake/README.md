# 0015 — Merge gate retries a third time on a transient structured-output flake

- **Date:** 2026-07-20
- **Issue:** Verjson/.github#64 (ai-review intermittently fails with `error_max_structured_output_retries`)
- **PR:** Verjson/.github#68
- **Category:** CI / merge-gate behavior (sensitive class)
- **Relationship:** Extends ADR 0002 (graceful budget/turn escalation) — same
  ai-review escalation ladder, a different failure mode.

## Context

The `ai-review` job asks Claude for a structured JSON verdict (`--json-schema`).
It already retries once (ADR 0002): a cheap first pass (`claude`), then an
escalation to the strong tier (`claude_retry`) when the first returns empty
structured output — the signal for budget/turn exhaustion.

But the action can also return **empty** for a different reason:
`error_max_structured_output_retries` — the model simply failed to emit the
tool-call verdict within the action's own retries. This is a **transient** flake,
not a size problem, and on 2026-07-20 it struck the first pass **and** the
escalation in the same run (#64), so the deterministic submit had no verdict and
failed closed. Observed ~50% of runs flaked while others in the same window
passed — roughly independent per attempt.

Failing closed is correct (never merge unreviewed), but the flake stalled
otherwise-approved merges and forced manual re-kicks.

## Decision

Add **one more bounded attempt** — a second strong-tier escalation
(`claude_retry2`, `claude-sonnet-5`, 30 turns, \$1.00) — guarded to fire **only
when both prior passes produced no verdict**
(`steps.claude.outputs.structured_output == '' && steps.claude_retry.outputs.structured_output == ''`).
The deterministic submit then prefers the newest non-empty verdict:
`claude_retry2 → claude_retry → claude` (mirrored in the telemetry payload).

Because the flakes are roughly independent, a third attempt clears the run far
more often than not (≈⅞ across three ~50% attempts). Fail-closed is unchanged: the
new step is `continue-on-error`, and if it too returns empty the submit still
labels `ai-review-inconclusive`, comments, and refuses to merge.

This is a **mitigation**, not a root-cause fix: if the flake rate stays high, the
next step is to distinguish the action's failure subtype (retry the cheap tier on
`error_max_structured_output_retries`, escalate only on budget/turns) or revisit
the model/schema interaction. #64 stays open to track that.

## Consequences

- A single transient structured-output flake no longer stalls a merge; it takes
  three independent flakes in one run to fall back to the manual path.
- Cost: at most one extra strong-tier pass, and only when two passes already
  produced nothing — never on a clean review.
- Fail-closed behavior and the inconclusive comment/label are preserved (comment
  reworded to cover "no verdict across all three passes").
- Pinned by `scripts/ci-gate/ai-review-retry.test.sh` (wired into `actions-ci`):
  three passes present, the dual-empty guard, the verdict fallback order, and the
  `continue-on-error` property — mutation-tested.

## Effective change (sensitive hunks)

```diff
+      - name: Second escalation when both prior passes produced no verdict (#64)
+        id: claude_retry2
+        if: steps.claude.outputs.structured_output == '' && steps.claude_retry.outputs.structured_output == ''
+        continue-on-error: true
+        uses: anthropics/claude-code-action@v1
+        with: { … same strong-tier config as claude_retry … }
```
```diff
-          VERDICT: ${{ steps.claude_retry.outputs.structured_output != '' && steps.claude_retry.outputs.structured_output || steps.claude.outputs.structured_output }}
+          VERDICT: ${{ steps.claude_retry2.outputs.structured_output != '' && steps.claude_retry2.outputs.structured_output || (steps.claude_retry.outputs.structured_output != '' && steps.claude_retry.outputs.structured_output || steps.claude.outputs.structured_output) }}
```

Full change: Verjson/.github#68.

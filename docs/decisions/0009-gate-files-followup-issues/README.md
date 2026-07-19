# 0009 — Merge gate files tracking issues for substantive non-blocking findings

- **Date:** 2026-07-18
- **Issue:** Verjson/.github#43 (nitpicks → standards → linter roadmap; this is its first step)
- **PR:** Verjson/.github#45
- **Category:** CI / merge-gate behavior
- **Relationship:** Extends the cost-lane merge gate; builds on the review-output
  schema introduced with ADR 0007's pinpointing (`review_first`).

## Context

The gate surfaces its review findings only in the PR comment. **Blocking**
findings hold the PR, so they can't be lost. But a **substantive non-blocking**
finding — a real bug or improvement the reviewer judged not worth blocking the
merge for — lives only in that comment, and evaporates once the PR merges and
scrolls out of view. Nothing tracks "we let this merge but should follow up."

We want those captured **without** flooding the tracker: filing an issue per
style/formatting nitpick would bury the substantive ones and cut against the
"keep the tracker for actioned work" policy. (The longer-term aim — mining
recurring nitpicks into codified standards and a linter — is tracked separately
in #43; this ADR is its first, structural step.)

## Decision

1. The review verdict schema gains a **`followups`** array (`{location, note}`).
   The prompt directs the reviewer to put **substantive non-blocking findings**
   there, and to keep **pure style/formatting/naming nitpicks out** (those stay
   in the summary prose only). This is the human-set threshold — option (a): file
   the substantive, not the trivial.
2. When a PR is **approved and actually merges**, the `ai-merge` job files **one
   tracking issue per `followups` entry** in the PR's repo, labelled
   `ai-review-followup`, each linking back to the PR and quoting the finding.
3. **Filed once, on merge only.** The step checks the PR is `MERGED` (not merely
   that the merge step exited 0). Dedup is **per-finding**, keyed on a content
   hash marker (`<!-- ai-review-followup:pr<N>:<hash> -->`), so a re-run (e.g.
   `workflow_dispatch` on a merged PR, or a retry after a partial failure) re-files
   only the findings that are actually missing — never the whole batch, and never
   a duplicate. A still-open PR files nothing — it may still fix the finding on
   the next push.
4. **The AI never closes or triages these issues** — it only opens them. Humans
   own the backlog; this just makes sure nothing substantive is silently dropped.

The gate still **never auto-adjusts merge/verification gates** (ADR 0006 / 0007);
opening a tracking issue is observe-and-report, not enforcement.

## Consequences

- Substantive findings on merged PRs become durable, actionable backlog items
  instead of evaporating in a comment; blocking findings are unchanged (they
  still hold the PR).
- Trivial nitpicks stay out of the tracker (threshold = substantive only),
  keeping it signal-rich. Their eventual promotion to standards/lint lives in #43.
- Cost: a few `gh issue create` calls per merged AI-reviewed PR with follow-ups;
  none for fast-lane / Renovate / finding-free merges.
- No new secrets/permissions: reuses `ORG_ADMIN_TOKEN` (already used for the
  cross-repo merge) to open issues in the target repo.
- The filing logic is committed (`ai-review-merge.yml`) and unit-tested by
  extraction (`scripts/ci-gate/followup-issues.test.sh`) — merged-only gating,
  per-PR dedup, one-issue-per-finding, empty/absent no-op.

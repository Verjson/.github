# 0012 — Merge gate honors a `DO NOT MERGE` label as a terminal hold

- **Date:** 2026-07-20
- **Issue:** Verjson/.github#51 (held PRs can be auto-merged)
- **PR:** Verjson/.github#55
- **Category:** CI / merge-gate behavior (sensitive class — ruleset/hold semantics)
- **Relationship:** Same subsystem as ADR 0008 (auto-update stale branches) and
  ADR 0009 (follow-up issues); hardens the opt-out guard the gate has carried
  since ADR 0001.

## Context

The org merge gate (`ai-review-merge.yml`) merges approved PRs with an org-admin
ruleset **bypass** — the same mechanism that lets it steamroll branch protection.
Its safety valve is a set of **opt-out (hold) signals** a human can raise to keep
a PR open regardless of review verdict or automerge eligibility.

The gate recognized three: a **`hold` label**, a **`DO NOT MERGE` title marker**,
and **draft**. But the verJSON workspace convention (workspace `CLAUDE.md`) is
"anything **titled or labelled** `DO NOT MERGE`", and the natural maintainer
action is to apply a **`DO NOT MERGE` label** — which matched *none* of the three
signals. So a PR a human explicitly held with that label could be auto-merged
(#51, observed during Renovate auto-merge verification: the gate honored the
ruleset bypass but ignored the do-not-merge hold).

This is a **sensitive-class regression** in ruleset/hold behavior, and it is the
**named blocker** on rolling out org-wide **PM autonomous merge authority**: that
grant is only safe once the gate reliably refuses to merge held PRs. Until this
fix, the only guard was PMs honoring the hold-list by hand — the fragile
"everyone must remember" state the grant is meant to eliminate.

## Decision

Fold a **`DO NOT MERGE` label** into the same terminal-hold predicate as `hold` /
title / draft, at every checkpoint, with the **merge-time bash re-check as the
authoritative gate**:

1. The two bash predicates (classify-time and merge-time) now normalize each
   label name — `ascii_upcase | gsub("[ _-]+"; " ")` — and hold if any equals
   `HOLD` or `DO NOT MERGE`. This is **case- and separator-insensitive**, so
   `do-not-merge`, `Do_Not_Merge`, and `DO NOT MERGE` all hold; the title match
   is likewise case-folded. The merge-time re-check reads live PR state, so a
   label added *after* classification still stops the merge.
2. The two GitHub-expression `if:` guards (freshness, classify) gain
   `!contains(labels.*.name, 'DO NOT MERGE')` so a held PR is skipped before it
   spends a review run. These are best-effort first-line filters; expression
   syntax can't case-fold, so separator/case variants are caught by the
   authoritative bash re-check, not here.

Holding is **fail-closed**: broadening the match can only *add* holds, never
merge something previously held.

## Consequences

- A `DO NOT MERGE` label now holds a PR open exactly like the title marker —
  closing the #51 gap and removing the last unguarded path. **This unblocks the
  org-wide PM autonomous-merge-authority rollout**, which was explicitly held
  behind this fix; the gate is now the reliable guard, not human vigilance.
- Existing signals (`hold` label, `DO NOT MERGE` title, draft) are unchanged and
  regression-tested; `hold` matching also became case-insensitive (a safe
  superset).
- No new secrets/permissions; pure predicate change in `ai-review-merge.yml`.
- Unit-tested by extraction (`scripts/ci-gate/hold.test.sh`): the #51 label case,
  separator/case variants, all prior signals, a positive-control green merge, and
  the non-open no-op — pinned to the shipped `merge` step so the test can't drift.

## Effective change (sensitive hunks)

```diff
     !contains(github.event.pull_request.labels.*.name, 'hold') &&
+    !contains(github.event.pull_request.labels.*.name, 'DO NOT MERGE') &&
     !contains(github.event.pull_request.title, 'DO NOT MERGE')
```
```diff
-if jq -e '(.labels | map(.name) | index("hold")) or (.title | contains("DO NOT MERGE")) or .isDraft' <<<"$meta" >/dev/null; then
+if jq -e '([.labels[].name | ascii_upcase | gsub("[ _-]+";" ")]) as $l | ($l | index("HOLD")) or ($l | index("DO NOT MERGE")) or (.title | ascii_upcase | contains("DO NOT MERGE")) or .isDraft' <<<"$meta" >/dev/null; then
```

Full change: Verjson/.github#55.

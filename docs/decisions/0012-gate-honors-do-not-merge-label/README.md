# 0012 — Merge gate honors a `DO NOT MERGE` label as a terminal hold

- **Date:** 2026-07-20
- **Issues:** Verjson/.github#51 (held PRs can be auto-merged),
  Verjson/.github#88 (removing a hold does not re-fire the gate)
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

## 2026-07-21 amendment — re-fire after removing a terminal hold

The documented review flow applies `hold`, marks a draft ready, and removes the
hold after the independent review passes. Removing a label emits an `unlabeled`
event, but the gate did not subscribe to that event, so the PR remained stranded
with stale skipped jobs until an unrelated push or manual dispatch (#88).

The gate now subscribes to `unlabeled`, but both pre-run job guards admit that
event only when the removed label is exactly `hold` or `DO NOT MERGE`. Removing
an unrelated label remains a no-op. The existing `labeled` path remains limited
to the explicit `re-review` request. Workflow concurrency likewise cancels an
active run only for gate-control label changes; the gate's own removal of
`re-review` cannot cancel the review that consumed it. Live hold-state checks
still run afterward, so removing one terminal signal cannot advance a PR that
retains another.

This restores the intended terminal-hold lifecycle without broadening arbitrary
label changes into paid review runs. The trigger and both job predicates are
regression-tested in `scripts/ci-gate/hold.test.sh`.

## 2026-08-07 amendment — the hold check must fail closed, not merely exist

Issue: [Verjson/.github#480](https://github.com/Verjson/.github/issues/480)
(duplicate #482 closed into it). Sensitive class; amending rather than
superseding, because this restores the invariant this ADR already decided instead
of deciding anything new.

Both checkpoints evaluated the hold as `if jq -e '<predicate>' <<<"$meta"`. `jq -e`
exits non-zero when the predicate is **false** *and* when jq itself **errors** —
malformed JSON, a truncated API response, a field the filter cannot index — and
`if` cannot distinguish the two. So "the hold could not be evaluated" was read as
"not held", and the gate proceeded toward merge. The decision above was correct
and the predicate was correct; the *evaluation* inverted it in exactly the
circumstance where a human most needs it to hold.

This was not theoretical. Executing the shipped merge block against a stubbed
`gh`, **three of six malformed metadata fixtures reached `gh pr merge`** — an
autonomous merge past a live `hold`. The remaining three exited 0 without
merging, which reports success for a decision never made.

Both checkpoints now materialise the predicate into a `true`/`false` string and
branch on it, so a jq error aborts under `set -e` and any third value fails closed
explicitly. This is the form `gate-rearm.yml` already used from the start (ADR
0063), so the three copies now agree on shape as well as on text.

**A third site is fixed under the same issue, and it is not a hold.** The
sensitive-path model selector (`ai-review-merge.yml`, `sensitive=`) chose
`claude-sonnet-5` at a $0.50 budget for paths matching
`auth|rbac|rls|abac|secret|payment|ledger|webhook|middleware|polic|.github/`, and
`claude-haiku-4-5` at $0.15 otherwise. A jq error there read as "not sensitive",
silently downgrading an auth or RBAC change to the weak model at 30% of the
budget — failing open on how hard the security review tries, on precisely the
changes the classifier exists to escalate. It also chained into #441: the smaller
budget makes `error_max_budget_usd` likelier, and a budget-exhausted pass emits a
non-blocking placeholder verdict the gate accepts. Chained, an unreadable file
list yields a green "reviewed" auth PR that was never reviewed, with no step
reporting a problem.

**Deliberately NOT changed: the cheap-lane detectors.** `submodule-only`,
`docs-only` and `deletions-only` keep `if jq -e`, because there a jq error reads
as "not eligible for the cheap lane" and the PR falls through to a full AI
review — fail-closed already. Sweeping every `if jq -e` in the file would have
turned three safe downgrades into hard errors while looking like progress. The
direction of each site's failure is what decides whether it is a defect, and
`budget-exceeded.test.sh` now pins that these three keep the old form.

The empty-diff short-circuit is also unchanged: `nfiles == 0` routes to
`lane=ai` with the cheap model and the reason `empty diff — needs a look`, which
is correct on its own terms (no files, so no sensitive paths) and is not the
unreadable-response case, since the fetch runs under `set -o pipefail` and a 5xx
fails the step outright. A test pins that an empty diff reaches that *named* path
rather than arriving at the classifier and picking the cheap tier by accident —
same model and budget, different reason, so only the reason distinguishes them.

Regression coverage executes the extracted `run:` blocks against a stubbed `gh`
rather than grepping for the fixed shape, so a rewrite that reintroduces the
fail-open breaks the tests: six malformed-metadata fixtures in
`scripts/ci-gate/hold.test.sh`, and the classifier fixtures plus both positive
controls in `scripts/ci-gate/budget-exceeded.test.sh`.

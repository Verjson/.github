# 0019 — Merge gate skips the paid re-review on a base-merge-only re-fire

- **Date:** 2026-07-22
- **Issue:** Verjson/.github#120
- **Category:** org merge-gate behavior (sensitive class)

## Context

When `main` is active, a green PR falls behind, `preflight` updates the branch,
and the resulting `synchronize` re-fires the whole gate — including a fresh
**paid** AI review — even though the PR's own net diff is unchanged (only a
base-merge/rebase was added). Two costs:

1. **$ + latency:** every base-merge re-runs the model; the longer review window
   also loses the merge race more often when `main` keeps moving.
2. **Red required-check thrash:** `concurrency.cancel-in-progress` cancels a
   `synchronize`-superseded run, and a cancelled `gate` job reports the required
   check red, so the PR shows BLOCKED until a fresh run wins a clean pass. Under
   sustained `main` churn a PR can sit stuck.

Observed live on #114 — a clean, independently-reviewed PR that never converged
through the gate under active `main` and had to be admin-merged. (The
cancelled-run-leaves-a-red-check half is deferred to a follow-up on #120; it
needs its own concurrency-behavior validation. This ADR covers only the
re-review skip.)

The `preflight`/classify job has no checkout, but the `gate` job does (and it is
where the approval marker is written) — so all git work for the patch-id lives
in `gate`.

## Decision

The `gate` job computes the PR's **net patch-id** (`git patch-id --stable` over
`git diff <merge-base> HEAD`, base ref fetched into the depth-2 checkout).
`git patch-id --stable` is invariant to later base-merges/rebases, so it is a
stable identity for "the change this PR actually makes." That patch-id is
embedded in the approval marker alongside the existing head SHA:
`<!-- ai-review-head:SHA patchid:PID model:M -->` (token order preserved; the
`ai-review-head:` token is unchanged for anything that greps it).

Before the model step, the gate reads the PR's reviews/comments, finds the most
recent **approval** marker (an `APPROVED` review or the self-gate's
"approved verdict" comment fallback — a blocking/inconclusive record never
qualifies), and sets `skip_model=true` **only** when a prior marker exists AND
its `patchid` is non-empty AND equals the current non-empty patch-id. On a skip,
the model steps are guarded off and the deterministic submit consumes a
synthesized approved (`blocking=false`) verdict, so the existing authoritative
merge-recheck + squash runs exactly as on a normal approve.

Correctness is unchanged: the merge only ever happens through the unchanged
recheck, which still fails closed on a moved head, red/pending CI, `hold` /
`DO NOT MERGE`, or draft. Every ambiguous case — no merge-base, empty diff,
missing/old/parse-failed/blocking-only marker, different patch-id — falls
through to the full review. The skip is purely a cost/latency optimization on an
already-approved, unchanged diff.

Pinned by `scripts/ci-gate/rereview-skip.test.sh` (and the marker token by
`review-comment.test.sh`), both wired into `actions-ci.yml`.

```diff
 # Approval marker (Submit deterministic PR review step)
-<!-- ai-review-head:${HEAD_SHA} model:${MODEL} -->
+<!-- ai-review-head:${HEAD_SHA} patchid:${PATCH_ID:-} model:${MODEL} -->

 # New gate step, after "Checkout PR head", before the model:
+skip=false; patch_id=""; approved_head=""
+base_ref="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json baseRefName --jq .baseRefName || true)"
+# fetch base into the depth-2 checkout, find the merge-base, take a stable patch-id
+mb="$(git merge-base "origin/$base_ref" HEAD || true)"
+[ -n "$mb" ] && diff="$(git diff "$mb" HEAD || true)"
+[ -n "${diff:-}" ] && patch_id="$(printf '%s\n' "$diff" | git patch-id --stable | awk '{print $1}')"
+# most-recent APPROVAL marker only (blocking/inconclusive never qualifies)
+if [ -n "$patch_id" ]; then
+  prior_patch="$(... jq APPROVED reviews + 'approved verdict' comments, newest, grep patchid ...)"
+  [ -n "$prior_patch" ] && [ "$patch_id" = "$prior_patch" ] && skip=true
+fi
+# skip -> synthesize an approved verdict; the unchanged merge-recheck still merges

 # Model steps gated off on a skip:
-if: needs.preflight.outputs.lane == 'ai'
+if: needs.preflight.outputs.lane == 'ai' && steps.rereview.outputs.skip_model != 'true'
```

## Consequences

- Rebased/base-merged re-fires of an already-approved, unchanged PR are
  near-instant and $0, which also shrinks the window in which a run can be
  superseded and thrash the required check.
- Fail-closed posture is preserved end-to-end: no path merges without either a
  fresh model approval or a byte-exact match to a prior approval, and the
  authoritative recheck is untouched.
- Old approval markers (pre-#120, no `patchid:` token) never match, so the
  transition degrades safely to a full review.
- Deferred (own follow-up on #120): the cancelled-superseded-run-leaves-a-red
  required check. It needs concurrency-behavior validation before shipping.

# 0013 — Merge gate tries update-branch before holding on a conflict

- **Date:** 2026-07-20
- **Issue:** Verjson/.github#56
- **PR:** Verjson/.github#57
- **Category:** CI / merge-gate behavior (sensitive class)
- **Relationship:** Extends ADR 0008 (freshness job auto-updates stale branches).
  Refines only the `CONFLICTING` branch of that decision; does not supersede it.

## Context

ADR 0008 added the `freshness` job to `ai-review-merge.yml`. It handles a branch
that is merely `BEHIND` its base by calling `update-branch` (merge the base into
head), then stepping aside so the resulting `synchronize` re-enters the gate
against the current base. But on `mergeable == CONFLICTING` (DIRTY) it held
immediately — posting the deduped `gate:branch-conflict` comment **without
attempting any update**.

GitHub's `mergeable` flag is computed pessimistically: a branch can read
`CONFLICTING` when the only real issue is base drift (non-overlapping changes on
`main` that a plain merge would reconcile cleanly). ADR 0008 already resolves that
exact drift for a `BEHIND` branch via `update-branch` — but the `CONFLICTING`
path never gave the branch that same chance, so a PR that a one-click "Update
branch" would clear was instead held for a human rebase. That is avoidable toil
and inconsistent with the BEHIND path's own remedy.

## Decision

On `CONFLICTING`, **first attempt the same non-destructive `update-branch`
merge** the BEHIND path uses (`PUT /repos/{repo}/pulls/{n}/update-branch`), then
re-check mergeability (waiting out the async `UNKNOWN` window exactly as the
initial read does):

1. **Cleared** (mergeable no longer `CONFLICTING`) → treat it like the BEHIND
   success path: the update pushed a `synchronize`, so a fresh run reviews/merges
   against the current base and this run steps aside (`proceed=false`, so
   `classify`/`ai-review`/`ai-merge` skip).
2. **Genuine content conflict** (the `update-branch` API fails, or mergeable is
   still `CONFLICTING` afterwards) → fall back to the **unchanged** ADR-0008
   behavior: hold (fail-closed, exit 1) + the single marker-guarded
   `gate:branch-conflict` comment asking for a rebase.
3. **Renovate PRs** → unchanged: still exempt via the existing anchored
   author/branch-prefix check, which runs *before* the mergeable check, so no
   update is attempted (Renovate owns its own rebases).

This is a **merge, never a rebase-and-force-push** — same guarantee as ADR 0008,
so it stays git-revertible.

### Honest limitation

`update-branch` is a **merge**, not a rebase. It therefore resolves BEHIND /
non-overlapping base drift, but it does **not** resolve a *true* content conflict
(overlapping edits to the same lines) — that still holds for a human. It also does
**not** address the squash-divergence / patch-id case (a branch that conflicts
because `main` already contains an equivalent squashed change), which only a
rebase that drops the already-applied commits can dedup — tracked separately in
#55. This ADR deliberately does **not** introduce a rebase; it only extends the
existing merge remedy to the conflict path.

## Effective change (sensitive hunks)

The changed predicate in the `freshness` step of `ai-review-merge.yml` — the
`CONFLICTING` branch now attempts `update-branch` and re-checks before holding:

```diff
-          # Hard conflict with base: cannot auto-resolve. Hold (fail-closed) and
-          # leave a single marker-guarded comment so a human knows to rebase.
           if [ "$mrg" = "CONFLICTING" ]; then
+            if gh api --method PUT "repos/$REPO/pulls/$PR_NUMBER/update-branch" >/dev/null 2>&1; then
+              # Re-read mergeable, again waiting out the async UNKNOWN window.
+              mrg="$(jq -r '.mergeable // "UNKNOWN"' <<<"$(pr_json mergeable || echo '{}')")"
+              for _ in 1 2 3 4 5 6; do
+                [ "$mrg" != "UNKNOWN" ] && break
+                sleep 5
+                mrg="$(jq -r '.mergeable // "UNKNOWN"' <<<"$(pr_json mergeable || echo '{}')")"
+              done
+              echo "post-update mergeable=$mrg"
+              if [ "$mrg" != "CONFLICTING" ]; then
+                echo "Conflict was base drift; update-branch cleared it — a fresh run will merge against the current base."
+                out proceed false; exit 0
+              fi
+            fi
             marker="<!-- gate:branch-conflict -->"
             note="$marker This PR conflicts with \`$base_ref\`. The merge gate can't auto-update a conflicting branch — please rebase/merge \`$base_ref\` and resolve the conflicts; the gate re-fires on push."
             if existing="$(pr_json comments)"; then
               jq -r '.comments[].body' <<<"$existing" 2>/dev/null | grep -qF "$marker" \
                 || gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$note" || true
             else
               gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$note" || true
             fi
             echo "::error::Branch conflicts with $base_ref — holding until resolved."
             exit 1
           fi
```

See the PR for the full change.

## Consequences

- A PR flagged `CONFLICTING` only because of base drift is now auto-cleared and
  re-entered against the current base — the same "no human Update-branch click"
  ergonomics ADR 0008 gave the BEHIND path, now extended to the conflict path.
- A genuine content conflict still fails closed, held with the same actionable
  comment before any model spend — the fail-closed guarantee is unchanged.
- **Cost:** at most one extra `update-branch` API call + a bounded mergeable
  re-poll per conflicting non-Renovate PR; the cleared case costs one extra CI
  cycle (the update-branch `synchronize`), identical to the BEHIND path.
- **No new secrets or permissions:** reuses `ORG_ADMIN_TOKEN` (already used for
  the cross-repo update-branch and comment in ADR 0008).
- **Sensitive-class** (org merge-gate behavior) → recorded here per policy, even
  though the operation itself (a merge) is git-revertible and touches no
  authn/authz, RBAC, IAM/OIDC, ruleset, or secret surface.
- Covered by extraction tests (`scripts/ci-gate/freshness.test.sh`): conflict
  cleared by update-branch (proceed=false, no comment), conflict + failed update
  (hold + comment), genuine conflict surviving update (hold + comment), and
  Renovate conflict still exempt — plus every prior ADR-0008 case still green.

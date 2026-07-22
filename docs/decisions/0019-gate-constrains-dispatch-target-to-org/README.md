# 0019 — Merge gate constrains its dispatch target to this org

- **Date:** 2026-07-22
- **Issue:** Verjson/.github#119
- **Category:** org merge-gate admin surface (sensitive class)

## Context

`ai-review-merge.yml` is the required org-wide merge gate, installed on every
repo via the main-protection ruleset. Its `preflight`/`ai-merge` jobs drive
`gh pr view`, `gh pr diff`, and `gh pr merge --admin` against `TARGET_REPO`
under `ORG_ADMIN_TOKEN` — a token whose ruleset bypass can squash-merge into a
protected `main`.

`TARGET_REPO` was `${{ inputs.repository || github.repository }}`, where
`repository` is a free-form `workflow_dispatch` input. Anyone able to dispatch
the workflow could therefore set `repository` to an **arbitrary** owner/repo and
point the admin-merge machinery at a repo the gate was never meant to touch — a
cross-repo admin-merge privilege-escalation surface. The `pull_request` trigger
path is unaffected (it always resolves to `github.repository`); the hole is the
dispatch input.

Tequity closed the equivalent surface in their downstream copies via **ADR-0027**
(`tequityapp/tequity-ui#16`) by dropping the input entirely and pinning
`TARGET_REPO: ${{ github.repository }}`. The org `.github` copy cannot simply drop
the input: operators legitimately re-gate a **sibling Verjson repo** by dispatch
(e.g. to re-fire the gate on a stuck PR in another org repo). The requirement is
therefore to keep the input but **bound it to the org**.

## Decision

Add an early `target_guard` step to the `preflight` job — before any
`gh pr view/merge` runs against `TARGET_REPO` — that fails closed unless the
target is an exact `<owner>/<repo>` whose owner equals `github.repository_owner`
(exported as `GITHUB_REPOSITORY_OWNER`, never hardcoded to `Verjson`):

```sh
owner="${TARGET_REPO%%/*}"
if [[ ! "$TARGET_REPO" =~ ^[^/]+/[^/]+$ ]] || [ "$owner" != "$GITHUB_REPOSITORY_OWNER" ]; then
  echo "::error::refusing to run the merge gate against '$TARGET_REPO': ..."
  exit 1
fi
```

- Default path (`repository` unset → `github.repository`) is same-owner → passes.
- `Verjson/other-repo` (operator re-gating a sibling) → same-owner → passes.
- `Attacker/evil` (foreign owner) → fails closed (`exit 1`).
- Malformed targets (`x`, `a/b/c`, `Verjson/`, empty) that are not exactly
  `<owner>/<repo>` → fail closed. When anything about the target is ambiguous, the
  gate rejects the dispatch rather than proceeding.

The input is retained; it is only bounded to the org. Downstream **single-repo**
consumers that never dispatch cross-repo should adopt the tighter ADR-0027 form:
drop the `repository` input and pin `TARGET_REPO: ${{ github.repository }}`. This
is documented in the workflow header as the recommended default for copies.

## Consequences

- The dispatch input can no longer aim `ORG_ADMIN_TOKEN` admin-merge at a foreign
  org; the worst an authorized dispatcher can do is re-gate a repo already inside
  the same org (which the gate already governs).
- Legitimate cross-sibling re-gating within the org keeps working, so no operator
  workflow is lost.
- A `scripts/ci-gate/dispatch-target-guard.test.sh` extraction test pins the guard
  against same-owner (pass), foreign-owner (fail), and malformed (fail-closed)
  targets, wired into `actions-ci.yml`, so a future edit cannot silently reopen the
  surface.
- The guard is purely a boundary check (no `gh`/network), so it adds negligible
  cost and cannot itself fail open on an API blip.

## Sensitive-hunk diff

```diff
+      - name: Constrain merge target to this org (fail closed)
+        id: target_guard
+        run: |
+          set -euo pipefail
+          # Everything below drives `gh pr view/merge` against TARGET_REPO under
+          # ORG_ADMIN_TOKEN. `repository` is a free-form workflow_dispatch input,
+          # so an arbitrary value would aim the admin-merge machinery at another
+          # org — a cross-repo admin-merge escalation (#119; Tequity ADR-0027,
+          # tequityapp/tequity-ui#16). Require an exact `<owner>/<repo>` whose
+          # owner is THIS org (github.repository_owner via env — never hardcode);
+          # anything else (foreign owner, or a malformed target) fails closed.
+          owner="${TARGET_REPO%%/*}"
+          if [[ ! "$TARGET_REPO" =~ ^[^/]+/[^/]+$ ]] || [ "$owner" != "$GITHUB_REPOSITORY_OWNER" ]; then
+            echo "::error::refusing to run the merge gate against '$TARGET_REPO': target must be a repo owned by '$GITHUB_REPOSITORY_OWNER'."
+            exit 1
+          fi
+          echo "merge target '$TARGET_REPO' is within org '$GITHUB_REPOSITORY_OWNER'."
+
       - name: Update branch if behind; hold on conflict
         id: freshness
```

See [PR #119](https://github.com/Verjson/.github/issues/119) for the full change.

# 0022 — Distribute the merge gate as a pinned cross-org reusable workflow

- **Date:** 2026-07-23
- **Issue:** Verjson/.github#128
- **Category:** org merge-gate behaviour + cross-org distribution (sensitive class)

## Context

`ai-review-merge.yml` is the required org merge gate, installed on every Verjson
repo through the main-protection org ruleset (`workflows` rule → this central
copy). Repos in **other orgs cannot consume a Verjson ruleset**, so they
hand-copy the workflow: Tequity maintains 5 copies (ADR-0027, #119). Those copies
**drift** — they receive no upstream fix and copy **none** of the
`scripts/ci-gate/*.test.sh` regression coverage. Concrete casualty:
`tequityapp/tequity-platform#38` — 4 copies still carry the pre-#106 unguarded
runner-timing arithmetic (the #124 fail-closed-abort class) and lack #110. Every
gate fix (#106, #110, #119, #120/#124, #126) has to be re-ported to each copy by
hand or it rots.

The gate was the **only** org workflow that wasn't reusable. `node-ci`,
`node-release`, `helm-ci`, `pulumi-ci`, `ui-ci` are all `workflow_call` reusables
consumed cross-repo via `uses: …@vX`, and #85 cut the moving-`v1` pin
infrastructure (`tag-major.yml`, ADR 0014). The gate should join them so upstream
fixes flow to every consumer automatically and the shipped `ci-gate` tests guard
the shared logic once for everyone.

## Decision

Expose the gate as a **`workflow_call` reusable** *in the same file* that keeps
its `pull_request` and `workflow_dispatch` triggers — one source of truth, three
entry paths — and parameterize the two org-specific assumptions. The five open
questions from #128 are resolved as:

1. **Trigger model — single file, three triggers (not a split).** The file lists
   `pull_request` + `workflow_dispatch` + `workflow_call`. The Verjson org ruleset
   keeps injecting it on `pull_request` unchanged; an operator re-gates via
   `workflow_dispatch`; a cross-org consumer adds a thin `uses:` caller that runs
   it under `workflow_call`. GitHub inherits the `github` context — including
   `github.event`, `github.repository`, and `github.repository_owner` — from the
   **caller**, so a consumer's `pull_request`-triggered caller supplies the PR
   number and repo to the reusable with no extra inputs. Routing the Verjson path
   through the reusable too was rejected: it would add a second required-check
   caller file to every repo for zero benefit and churn the live ruleset.

2. **Cross-org access — a manual repo setting, flagged for the human.** Cross-org
   `workflow_call` requires **Verjson/.github → Settings → Actions → General →
   Access = "Accessible from repositories in the enterprise"** (both orgs share
   one enterprise). This is a repo-settings change outside this PR and is called
   out in the report as the one manual prerequisite; without it, consumer callers
   fail to resolve the reusable.

3. **Runner parameterization — a `runner_labels` workflow_call input.** Both jobs'
   `runs-on` become
   `inputs.runner_labels && fromJSON(inputs.runner_labels) || <org fallback>`.
   On the org direct paths `inputs.runner_labels` is empty (the `inputs` context
   is unset outside `workflow_call`/`workflow_dispatch`), so the existing self-gate
   split is preserved unchanged: **Verjson/.github reviews its OWN PRs on `meta`**
   (deadlock avoidance, ADR 0016), every other org repo on `gate`. A consumer with
   a different fleet passes `with.runner_labels: '["self-hosted","gate"]'`.

4. **Secrets — `secrets: inherit`, never assume Verjson's token.** The reusable
   declares **no** `workflow_call.secrets` block; consumers pass `secrets: inherit`
   so their OWN `ORG_ADMIN_TOKEN` / `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`
   forward. The gate references `secrets.*` exactly as before — resolved from the
   caller's org under `workflow_call`, from Verjson's org on the direct path.

5. **Dispatch-target guard (#119, ADR 0020) — verified compatible.** The
   `target_guard` bounds `TARGET_REPO` to `GITHUB_REPOSITORY_OWNER`, a GitHub
   default env var equal to the **run owner** = the **caller's** owner under
   `workflow_call`. So the guard automatically bounds each consumer to its own org
   with no change — it was never Verjson-specific. `reusable-workflow.test.sh`
   asserts the guard stays org-relative (no hardcoded `Verjson`), and the existing
   `dispatch-target-guard.test.sh` still passes unchanged.

A new extraction/structural test `scripts/ci-gate/reusable-workflow.test.sh`
(wired into `actions-ci.yml`) pins all three triggers, the `runner_labels` input,
the parameterized `runs-on` on both jobs, the preserved self-gate split, and the
org-relative guard, so a future edit can't silently drop the reusable seam or
break the org path.

## Consequences

- Cross-org consumers pin `uses: Verjson/.github/.github/workflows/ai-review-merge.yml@v1`;
  upstream fixes reach them via the moving `@v1` (ADR 0014) with **no copies and
  no drift**, and the `ci-gate` suite guards the shared logic once for everyone.
- The Verjson org path is behaviourally unchanged: same `pull_request` trigger,
  same required check, same `meta`/`gate` self-gate split, same guard.
- **Manual prerequisite (flagged):** the Verjson/.github Actions access setting
  (item 2) must be widened to the enterprise before any cross-org caller works.
  Migrating Tequity's 5 copies to the reusable is follow-up work tracked from
  `tequityapp/tequity-platform#38`, owned by that org's PM.
- Adding `workflow_call` to a required-check workflow is merge-gate-behaviour +
  cross-org distribution — a sensitive class — hence this ADR and the held PR.

## Sensitive-hunk diff

```diff
 on:
   pull_request:
     types: [opened, reopened, ready_for_review, synchronize, labeled, unlabeled]
   workflow_dispatch:
     inputs:
       pr_number:
         description: PR number to review and (on pass) merge
         required: true
       repository:
         description: owner/repo the PR lives in (defaults to this repo)
         required: false
+  workflow_call:
+    inputs:
+      pr_number:
+        description: PR number to review; defaults to the caller's pull_request event
+        required: false
+        type: string
+      repository:
+        description: owner/repo the PR lives in; defaults to the caller repo
+        required: false
+        type: string
+      runner_labels:
+        description: 'JSON array of runs-on labels for the caller''s fleet …'
+        required: false
+        type: string
...
-    runs-on: ${{ github.repository == 'Verjson/.github' && fromJSON('["self-hosted","meta"]') || fromJSON('["self-hosted","gate"]') }}
+    runs-on: ${{ inputs.runner_labels && fromJSON(inputs.runner_labels) || github.repository == 'Verjson/.github' && fromJSON('["self-hosted","meta"]') || fromJSON('["self-hosted","gate"]') }}
```

Consumers pass `secrets: inherit`; the guard (`target_guard`) is unchanged and
stays bounded to `GITHUB_REPOSITORY_OWNER` = the caller's org. See
[PR #128](https://github.com/Verjson/.github/issues/128) for the full change.

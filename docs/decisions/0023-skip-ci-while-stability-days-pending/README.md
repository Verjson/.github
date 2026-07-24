# 0023 — Skip org CI while a PR is held by renovate/stability-days

- **Date:** 2026-07-24
- **Issue:** Verjson/.github#133
- **Category:** org CI-cost policy + branch-protection interaction (sensitive class)

## Context

When Renovate raises a PR whose `renovate/stability-days` age gate is still
**pending**, the merge gate already routes it to its `defer` lane — no model
review, no gate runner (`ai-review-merge.yml` classify). But the **org CI itself
ran the full suite anyway**, and that work is pure waste that re-burns on the
inevitable rebase.

Concrete casualty — `Verjson/toquorum#161` (a Renovate `lockFileMaintenance` PR,
`renovate/stability-days = pending`): the gate correctly skipped, yet the
hand-rolled `ci.yml` matrix ran **lint 19m37s · typecheck 21m14s · test 9m38s ·
build 20m50s** on a PR that could not merge. When `minimumReleaseAge` elapses,
Renovate rebases onto a now-drifted `main`, `synchronize` re-fires, and the whole
suite re-runs — the first run bought nothing, and base drift can add real rework
(conflict resolution, re-review). `internalChecksFilter: strict` holds *candidates*
back before a branch is raised, but replacement / `lockFileMaintenance` PRs bypass
it (exactly #161), so a CI-side guard is the robust general fix.

## Decision

Ship a small composite action **`.github/actions/ci-eligibility`** that checks the
PR head for a pending `renovate/stability-days` status — the same signal the gate
`defer`s on — and outputs `should-run`. Org CI adds a fast `eligibility` job and
gates its heavy jobs on it:

```yaml
build-test:
  needs: eligibility
  if: needs.eligibility.outputs.should-run == 'true'
```

- **`node-ci.yml` (reusable)** wires it in once, so every `node-ci` consumer gets
  it via `@v1`. The action is referenced as
  `Verjson/.github/.github/actions/ci-eligibility@v1`. It ships in the same repo
  as node-ci and the `v1` major tag is advanced atomically on release
  (`tag-major.yml`, ADR 0014), so it must **merge and retag together** — between
  merge and retag a consumer pinned to a newer node-ci ref (`@main`, a SHA) would
  resolve a `v1` lacking the action; the fail-open job gating below makes that
  transient run CI rather than wedge.
- **Token/permission (required for it to actually defer):** reading a commit's
  combined status needs the `statuses` permission, which `contents: read` does
  **not** confer, and a reusable's `GITHUB_TOKEN` is capped by the caller. So a
  consumer must add `statuses: read` to its caller `permissions:` block. Where it
  is absent the read is denied, the check **fails open**, and CI runs as before —
  a safe, opt-in rollout, not a hard break. The eligibility job requests
  `statuses: read` (not `contents: read`).
- **Hand-rolled CI** (`toquorum/ci.yml`, `catalog-*`, `viager-app`) adopts the
  same action in its own `eligibility` job. Those repos are `default-pm`'s — the
  org ships the action; each repo adopts it via its own PR. **toquorum#161 is the
  reference casualty and first adopter** (handed to default-pm).

Behaviour, as approved on #133:

- **Defer only on an ACTIVE pending status.** Any uncertainty — API error, missing
  status, or the eligibility *job* itself erroring — **fails OPEN** (CI runs), so a
  real PR is never silently skipped. This is enforced twice: the action's bash
  (`gh api … || echo 0`) and the job gate (`if: always() && … != 'false'`, which
  runs the suite when the eligibility output is empty). A `workflow_dispatch`
  always runs (explicit human override), mirroring the gate's dispatch-forces-review
  escape hatch.
- **What actually keeps a deferred PR from merging.** Skipping the heavy jobs is a
  CI-cost optimization, **not** the merge backstop — do not rely on
  skipped-required-check semantics, which branch protection often treats as
  passing, and `renovate/stability-days` is not itself a required check (ADR 0005).
  The real backstop is unchanged and independent of this change: the **merge gate
  routes the PR to its `defer` lane** (never approves/merges it) and **Renovate's
  own automerge honours `stability-days`**. So a deferred PR sits un-merged
  regardless of how branch protection scores the skipped checks.
- **Self-healing.** When `renovate/stability-days` clears, Renovate rebases onto
  fresh `main`, `synchronize` re-fires, the guard re-evaluates (status gone) → CI
  runs for real against the final base → the gate reviews → merges. The only way to
  linger is if Renovate never rebased, which the age gate always triggers (and
  `workflow_dispatch` forces a run).

A `scripts/ci-gate/ci-eligibility.test.sh` extraction test pins the four
behaviours (defer on pending, run when clean, fail-open on API error, dispatch
override), wired into `actions-ci.yml`.

## Consequences

- Deferred Renovate PRs stop burning the CI suite; it runs once, against the base
  it will actually merge on — no wasted run, no rebase-driven re-run of stale work.
- A deferred PR's heavy jobs show `skipped` until it rebases; it does not merge
  because the gate defers it and Renovate honours its own age gate (not because of
  skipped-check scoring). Self-heals on rebase; not a merge regression.
- The guard is fail-open and dispatch-overridable, so it can only ever *withhold*
  CI on a genuinely-held PR — never block a normal PR from being tested.
- The mechanism is one shared composite action + a single ci-gate test, so the
  logic is guarded once for every consumer instead of drifting across copies.
- Cross-repo adoption for hand-rolled CI is `default-pm`'s work, tracked from #133
  and toquorum#161.

## Sensitive-hunk diff

```diff
 jobs:
+  eligibility:
+    runs-on: ${{ fromJSON(inputs.runner) }}
+    permissions:
+      statuses: read            # NOT contents:read — reading a commit's status
+                                # needs `statuses`; caller must grant it too.
+    outputs:
+      should-run: ${{ steps.check.outputs.should-run }}
+    steps:
+      - id: check
+        uses: Verjson/.github/.github/actions/ci-eligibility@v1
+        with:
+          head-sha: ${{ github.event.pull_request.head.sha || github.sha }}
+          github-token: ${{ secrets.GITHUB_TOKEN }}
+
   build-test:
+    needs: eligibility
+    # fail OPEN: only an ACTIVE defer skips; an errored eligibility still runs CI
+    if: always() && needs.eligibility.outputs.should-run != 'false'
     runs-on: ${{ fromJSON(inputs.runner) }}
```

The action fails OPEN (`|| echo 0` → run) and forces a run on `workflow_dispatch`.
See [#133](https://github.com/Verjson/.github/issues/133) and the casualty
[toquorum#161](https://github.com/Verjson/toquorum/pull/161).

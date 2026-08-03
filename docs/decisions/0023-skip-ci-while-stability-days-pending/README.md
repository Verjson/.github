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
  it. The action is referenced **`@main`**, and Renovate is told **not** to
  digest-pin it. Rationale: node-ci is consumed `@main` across the org, but the
  moving `v1` tag lags `main` until a release is manually cut (`tag-major.yml`,
  ADR 0014). Any `v1`-based reference — or, worse, a digest Renovate resolves
  *from* `v1` — points at a commit predating this action → "action not found" for
  every `@main` consumer. This actually happened: **#135** (Renovate,
  `pinDigests: true` on node-ci.yml) pinned `ci-eligibility` to `9f36163 # v1`, a
  commit with no action. The fix is twofold: reference `@main` (a branch tip
  always resolves to a commit that has the co-located action), and add a
  `renovate.json` rule excluding this first-party self-reference from digest
  pinning (it has no supply-chain reason to pin, and pinning it is what broke it).
- **Token/permission (required for it to actually defer):** reading a commit's
  combined status needs the `statuses` permission, which `contents: read` does
  **not** confer, and a reusable's `GITHUB_TOKEN` is capped by the caller. So a
  consumer must add `statuses: read` to its caller `permissions:` block. The
  eligibility job explicitly requests `statuses: read` (not `contents: read`),
  so a caller that does not grant it makes the reusable call invalid at workflow
  startup. The action's fail-open behavior applies only after the workflow starts,
  such as when the status API returns an error.
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
override), plus the required caller-permission contract, wired into
`actions-ci.yml`.

## 2026-07-28 correction — caller permission omission fails at startup

Issue [#148](https://github.com/Verjson/.github/issues/148) showed that the
original "safe, opt-in rollout" wording was wrong at the reusable-workflow
boundary. [GitHub documents](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#supported-keywords-for-jobs-that-call-a-reusable-workflow)
that a called workflow can only maintain or reduce the caller's `GITHUB_TOKEN`
permissions; it cannot add a permission that the caller withheld. Because
`eligibility` explicitly requests `statuses: read`, omitting that grant does not
reach the action's runtime fail-open path: GitHub rejects the reusable call at
startup.

The failure was reproduced on `Verjson/verjson-authn#79`: restoring
`node-ci.yml@main` without the caller grant produced
[`CI` startup failure 30203052478](https://github.com/Verjson/verjson-authn/actions/runs/30203052478).
The next commit added `statuses: read` to the reusable-call job, after which
[`CI` run 30203321441](https://github.com/Verjson/verjson-authn/actions/runs/30203321441)
started and passed. The reported boundary is therefore still current and
observable, not merely inferred from documentation.

Keep the eligibility job's explicit `permissions:` block. Removing it would let
that job inherit every permission the caller supplies, broadening the token
available to the moving `@main` composite action. Requiring the caller's narrow
`statuses: read` grant preserves least privilege; the caller example and
regression test now state the startup requirement accurately.

## 2026-07-28 correction — immutable transitive action reference

Issue [#162](https://github.com/Verjson/.github/issues/162) supersedes the
original `@main` self-reference rationale. `@main` avoided the stale pre-action
release failure from #135, but made a SHA- or exact-SemVer-pinned `node-ci`
consumer execute mutable transitive code.

`node-ci` now pins `ci-eligibility` to
`9a7cc9cac4e0f32a5b64d8af8b8467350ee685d2`, the reviewed commit that introduced
the action. This keeps the action available while making the dependency
immutable. The obsolete Renovate `pinDigests: false` exception is removed.
Policy tests resolve co-located dependencies at their pinned commits, traverse
the live `uses:` graph, and reject branch, moving-major, and other non-SHA refs.
The action logic, `statuses: read` boundary, fail-open runtime behavior, and
`renovate/stability-days` semantics are unchanged.

## 2026-07-28 correction — eliminate the remote self-dependency

Issue [#164](https://github.com/Verjson/.github/issues/164) supersedes the manual
co-located action pin introduced for #162. Although immutable, that pin could
drift whenever the composite action changed. Teaching Renovate to maintain it
would create a loop: publishing this repository updates the self-pin, and
publishing that update moves the self-pin again.

`node-ci` therefore inlines the composite action's exact shell block in its
`eligibility` step. An extraction test requires byte-for-byte parity between the
inline block and `.github/actions/ci-eligibility/action.yml`, then exercises the
inline block against the existing behavior cases. The composite action remains
available to hand-rolled CI consumers; the reusable workflow no longer resolves
it through any remote ref. This preserves `id: check`, `GH_TOKEN`/`HEAD_SHA`,
`should-run`, `statuses: read`, fail-open job gating, dispatch override, and
`renovate/stability-days` behavior while removing both pin drift and the
transitive self-dependency.

## Consequences

- Deferred Renovate PRs stop burning the CI suite; it runs once, against the base
  it will actually merge on — no wasted run, no rebase-driven re-run of stale work.
- A deferred PR's heavy jobs show `skipped` until it rebases; it does not merge
  because the gate defers it and Renovate honours its own age gate (not because of
  skipped-check scoring). Self-heals on rebase; not a merge regression.
- The guard is fail-open and dispatch-overridable, so it can only ever *withhold*
  CI on a genuinely-held PR — never block a normal PR from being tested.
- Reusable and hand-rolled CI have separate YAML copies of the shell block, but
  the extraction test requires exact parity and exercises the reusable's copy,
  so behavior cannot drift between consumer paths.
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
+        uses: Verjson/.github/.github/actions/ci-eligibility@main  # co-located; not digest-pinned (renovate.json) — v1 lags main
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

The `@main` line above records the original sensitive hunk. The first 2026-07-28
correction replaced that ref with a reviewed full SHA; the #164 correction then
removed the remote `uses:` call and inlined the parity-guarded shell block.

## 2026-08-03 correction — release both merge-control runners on defer

Issue [#368](https://github.com/Verjson/.github/issues/368) found that the gate
and privileged merge had drifted from this decision even though CI eligibility
still deferred correctly. On `Verjson/verjson-upload#28`, CI eligibility skipped
the heavy job in six seconds, but gate job `91759710317` and privileged merge job
`91759669057` both remained active for more than 35 minutes while
`renovate/stability-days` was the only pending context.

The gate preflight queried commit statuses without requesting `statuses: read`.
That read failed, its deliberate uncertainty fallback returned zero, and the PR
entered a real gate instead of the `defer` lane. Independently,
`privileged_merge` started on `pull_request_target` and treated the same status as
generic pending work for its full 80-poll window.

The restored contract is end to end: preflight requests `statuses: read`, and
privileged merge terminates successfully when the attested head has an active
`renovate/stability-days` status. If that status appears after classification,
the gate fails immediately instead of polling. The privileged continuation is
itself always a `workflow_dispatch`, including automatic continuations, so that
event is not treated as operator authority to bypass a scheduler hold. Failed
statuses and same-named CheckRuns remain terminal failures.

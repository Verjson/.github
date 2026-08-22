# Verjson/.github — repo working notes

Org-level `.github`: the merge gate (`ai-review-merge.yml`), reusable workflows
(`helm-ci`/`pulumi-ci`/`ui-ci`), composite actions, and decision records. These
conventions augment the workspace and global `~/.claude` rules; where they
conflict, the more local one wins.

## Running log — add a NEXT/ fragment, never edit a shared file

This repo does **not** keep a prepend-only `NEXT.md`. In the same commit as a
change that affects behaviour, pins, docs, or config, add a **new** file
`NEXT/YYYY-MM-DD-issue-<issue-number>-<slug>.md` (see `NEXT/README.md` for
metadata and the issue-less exception).
Because no two PRs touch the same file, the log can't produce merge conflicts —
which is the whole point. Read the log with `scripts/render-next.sh`. `NEXT.md` is
a static pointer; don't add entries to it.

## ADRs — add a directory, let the index generate

Decisions live at `docs/decisions/NNNN-<slug>/README.md` with a `# NNNN — Title`
H1 and a `- **Date:** YYYY-MM-DD` line. **Do not hand-edit the index table** in
`docs/decisions/README.md` — run `scripts/gen-adr-index.sh` to regenerate it from
the ADR directories, and commit that. `actions-ci` runs `gen-adr-index.sh --check`
and fails if the committed table is stale. On a rebase, re-run the generator
instead of hand-merging table rows. Sensitive-class changes (auth/RBAC, rulesets,
runner topology, IAM/OIDC, secrets, merge-gate behaviour) still require an ADR.
For a bug fix that restores an invariant already recorded in an ADR, amend that
controlling ADR with the dated rationale and evidence; reserve a new ADR number
for a new or superseding decision. “Restoring intended behaviour” is not an
exemption from decision-record coverage.

## CI-gate tests

Gate shell tests execute the current named workflow steps against stubbed
dependencies or exercise checked-in helpers directly. Add or extend a behavioral
test for every gate change and register it in `scripts/actions-ci-groups.tsv`; an
unregistered test does not run in Actions.

## Autonomous batches — review before AI merge authority is enabled

The org gate defaults to human approval, but code, executable dependency,
workflow, policy, prompt, and agent-instruction changes automatically receive
one or two cumulative AI review passes. Generated lockfile-only and non-agent
documentation changes may use the no-model lane.
An operator can set `AI_REVIEW_AUTHORITY=ai-merge`, which can merge a green PR
in ~1–3 minutes before an out-of-band `code-reviewer` pass finishes. When that
authority is enabled for non-trivial or fanned-out autonomous work:

- Run the independent `code-reviewer` **before pushing**, or open the PR as a
  **draft** (the gate skips drafts) / apply the **`hold`** label until the review
  passes, then mark ready / remove `hold`. `DO NOT MERGE`/`hold` are honored as
  terminal holds (ADR 0012).
- Worktree agents may be cut from a **stale** base — fetch real `origin/main` and
  branch from it before working, and keep local `main` synced after squash-merges
  (remote is the source of truth; local `main` goes stale).
- PRs that touch shared append surfaces are conflict-prone when run in parallel;
  the `NEXT/` fragments + generated ADR index above remove the common cases.

## Active Issues / Areas for Improvement

Each entry states the concrete fact and how/when it was last verified — a live re-check,
not just inspection of prose (#956: an entry asserting external status should say how it
was confirmed, since inspection-only claims go stale silently).

- [#629](https://github.com/Verjson/.github/issues/629) — Protected canary and rolling runner deployment contract. Verified via issue comments 2026-08-22: the CLI-acquisition defect is fixed (PR #912), but still blocked on 3 external inputs only the repo owner can supply — a DigitalOcean project ID, a `production` deploy secret, and authenticated live canary/stop/rollback receipts.
- [#676](https://github.com/Verjson/.github/issues/676) — Route privileged merge continuations to disposable GitHub-hosted runners. Part 1 (hosted-compute availability) remains an owner-confirmed hold. Part 2 (the hardcoded `["self-hosted","general"]` fallback in `ai-privileged-merge.yml` that bypasses the lane variable) is still deliberately untouched: it's inert today (nothing depends on the flip while part 1 is blocked), and this is the single most security-sensitive file in the repo — a rushed edit here is worse than the known, well-documented gap. Needs a dedicated, unhurried session.
- [#699](https://github.com/Verjson/.github/issues/699) — Automate organization Renovate grouping and compatibility holds. Verified live 2026-08-22 via `gh api orgs/Verjson/actions/secrets`: `RENOVATE_COMPATIBILITY_PAT` still does not exist at the org level, so `renovate-grouping-plan.yml` / `renovate-compatibility-reconcile.yml` (both already merged, PR #961) cannot run. Needs an org owner to add the secret (or provision the dedicated App the ADR calls for).
- [#718](https://github.com/Verjson/.github/issues/718) — GitHub Packages has no per-customer entitlement; blocking paid distribution. Confirmed still a user-owned product decision as of the 2026-08-18 PM rescout: no accepted ADR selects a target registry/entitlement model or a public/gated package split. A narrower near-term unblock (a GitHub App installed in both `Verjson` and `tequityapp` with `read:packages`) is identified but not pursued.
- [#819](https://github.com/Verjson/.github/issues/819) — Spending-limit containment review. All prep work is done: Actions is confirmed off in all 19 dormant `viager*`/`scrm*`/`scv*` repos, and the `verjson-*` runner audit (feeding #676) confirms hosted spend is structurally bounded to `AiB`'s dispatch-only installer legs by ADR 0103 + `scripts/ci-gate/hosted-selector-policy.py`'s hardcoded allowlist. Whether it's now safe to raise the org spending limit is explicitly left for the owner.
- [#933](https://github.com/Verjson/.github/issues/933) — Generated caller pins go stale silently when an org-wide variable outruns a consumer's pinned contract SHA. Part 1 (`toquorum`'s stale pin) landed via `toquorum#636`. Part 2 (systemic drift-detection mechanism + ADR) dispatched to a delivery agent 2026-08-22 — see the open PR referencing #933 for status.
- [#975](https://github.com/Verjson/.github/issues/975) / [#994](https://github.com/Verjson/.github/issues/994) — The changelog contract has no release-caller mode for non-npm adopters (Electron/`AiB`, containers/`tequity-ui`). Dispatched to a delivery agent 2026-08-22 to add `release-artifact` / `release-container` modes to `gen-changelog-caller.sh` — see the open PR for status.
- [#983](https://github.com/Verjson/.github/issues/983) — ADR directory numbers are a global allocator; concurrent PRs collide. Dispatched to a delivery agent 2026-08-22 to add a CI check that fails a PR whose ADR number collides with `main` or another open PR — see the open PR for status.
- [#985](https://github.com/Verjson/.github/issues/985) / [#986](https://github.com/Verjson/.github/issues/986) — `node-ci.yml`'s `db-image` publishes to an unreachable host on this org's sibling-docker runners (probe detects it but only warns), and offers only Postgres/Redis service slots. Dispatched to a delivery agent 2026-08-22 — see the open PR for status.
- [#987](https://github.com/Verjson/.github/issues/987) — GitHub Packages retention deletes published `@verjson/*` versions out from under pinned consumers (hardcoded to exactly 3). Dispatched to a delivery agent 2026-08-22 to make the count configurable (default unchanged) and add a rename-deprecation-stub safety net; the "stop deleting vs. longer window" policy call stays with a human given its storage-cost tradeoff — see the open PR and the issue comment.
- [#731](https://github.com/Verjson/.github/issues/731) — Require the generated changelog-contract check in the canonical Node ruleset. Investigated 2026-08-22: the staged rollout's own read-only audit reported 22/22 node-stack repos nonconformant, including a sample generated fresh from this repo's own current generator — proof the audit's classifier (`scripts/required-checks-workflow.py`), not consumer drift, was the bug (stale since generator changes #638/#959). Fixed in PR #995. Real remaining drift persists in several consumer repos still pinned to a pre-#959 contract SHA — cross-repository work outside this repo's ownership boundary. The ruleset mutation itself stays behind the script's own explicit `human_gate_required` acknowledgement regardless.
- Several `scripts/ci-gate/*.test.sh` files are not registered in `scripts/actions-ci-groups.tsv` and so never run in Actions — they've drifted badly unnoticed: `dispatch-permission.test.sh` (28 failures as of 2026-08-19), `self-job-exclusion.test.sh`, `entry-workflow-provenance.test.sh`, `merge-branch-cleanup.test.sh`, `ci-wait-fail-closed.test.sh`, `required-workflow-provenance.test.sh` (all fail outright, "could not extract ... block"). Found while adding `#931`'s arm-receipt cleanup; out of scope there. Needs its own triage: register-and-fix or delete-as-dead per file.

Prune an entry when its issue closes. This list loads into every session, so a
closed entry costs context in each one and misreports the state of the work.

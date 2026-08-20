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

- [#931](https://github.com/Verjson/.github/issues/931) — **Blocks #701/#728 too.** Actions artifact storage quota exhausted org-wide; ~5.15GB of expired artifacts reclaimed 2026-08-19, but GitHub's usage counter can lag 6-12h — not yet empirically confirmed clear as of 2026-08-20T00:30Z. Re-check `verjson-browser-agent#46` / `verjson-cloud-storage#92`'s `arm` check after the window elapses.
- [#858](https://github.com/Verjson/.github/issues/858) — Make advisory AI outcomes visibly neutral without removing ADR 0090's human fallback.
- [#856](https://github.com/Verjson/.github/issues/856) — Completed DeepSeek responses lose typed extraction diagnostics when no verdict can be replayed.
- [#701](https://github.com/Verjson/.github/issues/701) — **Blocks the merge gate.** 15/17 previously-broken adopter repos now fixed; the remaining 2 (`verjson-browser-agent#46`, `verjson-cloud-storage#92`) are code-correct and blocked purely on #931 clearing.
- [#728](https://github.com/Verjson/.github/issues/728) — The 2026-08-08 gate outage; ruleset half fixed by ADR 0094, remainder closes on the same #931 trigger as #701.
- [#731](https://github.com/Verjson/.github/issues/731) — Require the generated changelog contract check in the canonical Node ruleset.
- [#933](https://github.com/Verjson/.github/issues/933) — Part 1 (bump `toquorum`'s stale `gate-rearm.yml` pin) landed via `toquorum#636` but not yet empirically confirmed (no post-merge arm run observed as of 2026-08-20). Part 2 (systemic drift-detection mechanism for stale consumer caller pins) not started — needs a dedicated design pass + ADR.
- [#676](https://github.com/Verjson/.github/issues/676) — Finish privileged caller regeneration and remove the temporary legacy route; blocked on GitHub-hosted compute availability for private privileged jobs (owner-confirmed hold).
- [#629](https://github.com/Verjson/.github/issues/629) — Protected canary and rolling runner deployment contract; blocked on 3 external inputs from the repo owner (DigitalOcean project ID, a `production` deploy secret, a `verjson-cloud` CLI-acquisition path).
- [#718](https://github.com/Verjson/.github/issues/718) — GitHub Packages has no per-customer entitlement; blocking paid distribution. Design-gated on a user-owned product decision (target registry/entitlement model).
- [#699](https://github.com/Verjson/.github/issues/699) — Renovate grouping/compatibility control plane; code side done (PR #908), blocked on an org admin provisioning a dedicated least-privilege GitHub App per ADR 0109.
- [#157](https://github.com/Verjson/.github/issues/157) — Cross-repo commit coverage for the rework reconciler; implementation and runbook merged (#183), blocked on an org admin provisioning `REWORK_RECONCILE_TOKEN`.
- [#819](https://github.com/Verjson/.github/issues/819) / [#810](https://github.com/Verjson/.github/issues/810) — REQ-10 runner-lane remediation; blocked on 6 unmanaged-repo PMs landing lane migrations or recording exceptions (one, `AiB#229`, just landed). No `.github`-side action item.
- Several `scripts/ci-gate/*.test.sh` files are not registered in `scripts/actions-ci-groups.tsv` and so never run in Actions — they've drifted badly unnoticed: `dispatch-permission.test.sh` (28 failures as of 2026-08-19), `self-job-exclusion.test.sh`, `entry-workflow-provenance.test.sh`, `merge-branch-cleanup.test.sh`, `ci-wait-fail-closed.test.sh`, `required-workflow-provenance.test.sh` (all fail outright, "could not extract ... block"). Found while adding `#931`'s arm-receipt cleanup; out of scope there. Needs its own triage: register-and-fix or delete-as-dead per file.

Prune an entry when its issue closes. This list loads into every session, so a
closed entry costs context in each one and misreports the state of the work.

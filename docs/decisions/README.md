# Decision log

Reverse-chronological index of org-level decisions.

> The table below is **generated** from each `NNNN-*/README.md` by
> `scripts/gen-adr-index.sh` (each row is the ADR's `# NNNN — Title` H1 + its
> `**Date:**`). Do not hand-edit it — add your ADR directory and run the script;
> CI (`actions-ci`) fails if the committed table is stale. This keeps concurrent
> ADR PRs from conflicting on a shared table.

<!-- BEGIN ADR INDEX -->
| # | Date | Decision |
|---|------|----------|
| [0019](0019-gate-skips-rereview-on-unchanged-diff/README.md) | 2026-07-22 | Merge gate skips the paid re-review on a base-merge-only re-fire |
| [0018](0018-gate-elides-lockfiles-from-review/README.md) | 2026-07-22 | Merge gate elides generated lockfiles from the AI review payload |
| [0017](0017-two-stage-ai-merge-gate/README.md) | 2026-07-21 | AI merge gate uses two runner assignments and one long CI wait |
| [0016](0016-self-gate-runner-redundancy/README.md) | 2026-07-20 | Self-gate runner lane must be redundant (second dedicated `meta` runner) |
| [0015](0015-gate-retry-structured-output-flake/README.md) | 2026-07-20 | Merge gate retries a third time on a transient structured-output flake |
| [0014](0014-reusable-workflow-versioning/README.md) | 2026-07-20 | Version & pin the org reusable workflows (moving major tag) |
| [0013](0013-gate-auto-update-on-conflict/README.md) | 2026-07-20 | Merge gate tries update-branch before holding on a conflict |
| [0012](0012-gate-honors-do-not-merge-label/README.md) | 2026-07-20 | Merge gate honors a `DO NOT MERGE` label as a terminal hold |
| [0011](0011-hostinger-runner-labels-capability-accurate/README.md) | 2026-07-19 | Runner labels describe capability: drop `GCP` from the `hostinger` runner |
| [0010](0010-platform-templates-consume-reusable-workflows/README.md) | 2026-07-19 | Platform-template service repos consume org reusable workflows |
| [0009](0009-gate-files-followup-issues/README.md) | 2026-07-18 | Merge gate files tracking issues for substantive non-blocking findings |
| [0008](0008-gate-auto-update-stale-branches/README.md) | 2026-07-18 | Merge gate auto-updates stale branches before review/merge |
| [0007](0007-adaptive-verification-blast-radius/README.md) | 2026-07-18 | Adaptive verification: scale review to blast radius, escalate on error rise |
| [0006](0006-ai-rework-telemetry-observe-and-report/README.md) | 2026-07-18 | AI-work rework telemetry: observe-and-report, human holds the dial |
| [0005](0005-defer-renovate-release-age-prs/README.md) | 2026-07-15 | Defer AI review of Renovate PRs whose release-age gate is still pending |
| [0004](0004-ci-telemetry-via-observability-action/README.md) | 2026-07-15 | Merge-gate CI telemetry via the verjson-observability action |
| [0003](0003-runner-groups-gcp-github-manish/README.md) | 2026-07-15 | Runner groups: GCP / GitHub (last resort) / manish |
| [0002](0002-ai-review-graceful-budget-escalation/README.md) | 2026-07-15 | AI merge gate: escalate on budget exhaustion instead of failing |
| [0001](0001-renovate-automerge-ai-review/README.md) | 2026-07-13 | Renovate auto-merge + org-wide advisory AI review |
<!-- END ADR INDEX -->

## When to write an ADR (vs a GitHub issue)

An **issue** tracks *work* — transient, open→closed, "what needs doing / is it done".
An **ADR** records a *decision* — durable, "why is it this way, what did we rule out".
An issue's value ends when it closes; an ADR's begins there — so decision rationale must
not live only in issue comments (they rot and aren't versioned with the code).

Default flow:

1. **An issue is the front door** — bugs, tasks, and proposals start as issues (triage,
   discussion, backlog).
2. **Write an ADR only when the resolution locks in an architecturally-significant or
   hard-to-reverse decision** (auth/RBAC, rulesets/branch protection, IAM/OIDC, secrets,
   runner topology, anything destructive — always). A bug fix, dependency bump, or "adopt
   the existing pattern" needs no ADR.
3. **Wire them both ways** — the ADR's Context cites the issue #; the issue links the ADR;
   the implementing PR links both (*what* = issue, *why* = ADR).
4. **Close the issue on merge; the ADR persists.**
5. **Never edit a decided ADR to reverse it** — add a new ADR that supersedes it and link
   both.

Format: one directory per decision, `NNNN-kebab-title/README.md` (next zero-padded number),
added to the table above (newest first).

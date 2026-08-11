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
| [0091](0091-ruleset-requires-authorization-arm/README.md) | 2026-08-10 | Require the authorization arm, not the dispatched AI review |
| [0090](0090-human-first-opt-in-ai-review/README.md) | 2026-08-10 | Keep human approval available when AI review is opted in |
| [0089](0089-caller-supplied-privileged-routing/README.md) | 2026-08-10 | Pass privileged routing through the trusted caller |
| [0088](0088-auditable-organization-secret-scope/README.md) | 2026-08-09 | Make organization secret scope auditable before mutation |
| [0087](0087-runner-free-event-driven-ai-gates/README.md) | 2026-08-09 | AI gates never hold runners waiting for external CI |
| [0086](0086-secretless-node-pr-validation/README.md) | 2026-08-09 | Separate Node dependency acquisition from secretless PR execution |
| [0085](0085-immutable-privileged-caller-contract/README.md) | 2026-08-09 | Pin privileged callers to immutable contract revisions |
| [0084](0084-programmatic-privileged-routing/README.md) | 2026-08-09 | Resolve privileged routing programmatically |
| [0083](0083-pin-ai-review-action-and-source-bot-logins/README.md) | 2026-08-09 | Pin the AI review action and name source bot logins |
| [0082](0082-receipt-bound-provider-budget-policy/README.md) | 2026-08-08 | Receipt-bound provider and budget policy |
| [0081](0081-event-driven-terminal-ai-promotion/README.md) | 2026-08-08 | Event-driven AI authorization ends in terminal privileged promotion |
| [0080](0080-one-automatic-paid-ai-review-per-head/README.md) | 2026-08-08 | Allow one automatic paid AI review per head |
| [0079](0079-head-bound-ai-authorization-and-native-auto-merge/README.md) | 2026-08-08 | Head-bound AI authorization and native auto-merge |
| [0078](0078-container-release-and-runner-deployment-contract/README.md) | 2026-08-08 | Container releases promote immutable candidates before protected deployment |
| [0077](0077-private-repository-gate-restoration/README.md) | 2026-08-07 | Restore private-repository gates without speculative signing |
| [0076](0076-bounded-actions-ci-shell-test-groups/README.md) | 2026-08-07 | Bound `actions-ci` shell tests into three parallel groups |
| [0075](0075-generated-artifacts-is-the-changelog-check-prefix/README.md) | 2026-08-07 | Generated artifacts is the changelog check prefix |
| [0074](0074-signed-gate-attestation-provenance/README.md) | 2026-08-07 | Privileged merge trusts signed gate provenance |
| [0073](0073-required-node-ci-context-always-reports/README.md) | 2026-08-07 | The required Node CI context always reports |
| [0072](0072-watchdog-cadence-is-observed-not-guaranteed/README.md) | 2026-08-07 | Watchdog cadence is observed, not guaranteed |
| [0071](0071-changelog-impact-governs-version-bumps/README.md) | 2026-08-07 | Changelog impact governs version bumps |
| [0070](0070-component-scoped-changelog-streams/README.md) | 2026-08-07 | Changelog components are explicit release streams |
| [0069](0069-node-publication-consumes-contract-version/README.md) | 2026-08-07 | Node publication consumes the changelog contract's version |
| [0068](0068-dispatch-honors-caller-runner-labels/README.md) | 2026-08-07 | The merge dispatcher honors the caller’s explicit runner fleet |
| [0067](0067-portable-ci-command-boundary/README.md) | 2026-08-07 | Portable CI commands stop at the GitHub control plane |
| [0065](0065-verified-changelog-tool-cache/README.md) | 2026-08-07 | Changelog tooling uses a verified runner cache |
| [0064](0064-privileged-merge-reaches-the-overflow-lane/README.md) | 2026-08-07 | The privileged merge poller reaches the overflow lane |
| [0063](0063-required-workflow-events-are-bridged/README.md) | 2026-08-06 | A required workflow only sees three activity types, so the rest are bridged |
| [0062](0062-release-verifies-before-it-tags/README.md) | 2026-08-06 | The release caller is generated, and it verifies before it tags |
| [0061](0061-changelog-check-is-required-for-adopters/README.md) | 2026-08-06 | The changelog check is a required status check, scoped by a repository property |
| [0060](0060-node-release-retired/README.md) | 2026-08-06 | `node-release.yml` is retired: a release is dispatched, never derived from a merge |
| [0059](0059-released-snapshots-carry-the-release-note/README.md) | 2026-08-05 | Released snapshots carry the release note; the running log keeps the argument |
| [0058](0058-github-waits-for-checks-not-the-gate/README.md) | 2026-08-05 | GitHub waits for required checks; the gate stops being an orchestrator |
| [0057](0057-runner-labels-optional-lane-routed-callers/README.md) | 2026-08-05 | `runner_labels` is optional again, so generated callers route by lane |
| [0056](0056-fleet-watchdog-retained-and-retargeted/README.md) | 2026-08-05 | Keep the fleet watchdog, retargeted at the poll job the overflow lane cannot reach |
| [0055](0055-shared-generated-artifact-checks/README.md) | 2026-08-05 | Generated-artifact validation is a shared workflow with enumerated checks |
| [0054](0054-public-repositories-admitted-to-the-general-pool/README.md) | 2026-08-05 | Admit public repositories to the self-hosted general pool |
| [0053](0053-overflow-lane-for-polling-gate-jobs/README.md) | 2026-08-05 | One reversible overflow lane for jobs that poll the pool they wait on |
| [0052](0052-release-push-token-satisfies-branch-rules/README.md) | 2026-08-04 | The changelog release push needs a credential the branch ruleset bypasses |
| [0051](0051-ai-review-pr-head-evidence-boundary/README.md) | 2026-08-03 | AI review does not infer base state from the PR checkout |
| [0050](0050-actionlint-fast-lane-for-public-targets/README.md) | 2026-08-03 | actionlint takes the fast lane on public targets |
| [0049](0049-fleet-watchdog-preempts-poll-jobs/README.md) | 2026-08-03 | A watchdog preempts merge-gate poll jobs on the self-hosted fleet |
| [0048](0048-merge-gate-fast-lane-by-visibility/README.md) | 2026-08-03 | Merge-gate jobs take the fast lane when the target is public |
| [0047](0047-fast-lane-runner-variable/README.md) | 2026-08-03 | A fast lane for short CI jobs, selected by variable |
| [0046](0046-baseline-repository-hygiene/README.md) | 2026-08-02 | Baseline repository hygiene: a root README that answers three questions |
| [0045](0045-pin-validation-fetches-by-sha/README.md) | 2026-08-02 | Pin validation fetches by SHA, so it proves immutability but not reachability |
| [0044](0044-gate-provenance-bound-to-entry-workflow/README.md) | 2026-08-02 | Gate provenance is bound to the run's entry workflow |
| [0043](0043-privileged-merge-verifies-its-own-revision/README.md) | 2026-08-01 | Privileged merge verifies which revision of itself is executing |
| [0042](0042-privileged-merge-reusable-split/README.md) | 2026-08-01 | Privileged merge becomes a reusable workflow with a two-sided name contract |
| [0041](0041-shared-admission-hosted-and-self-hosted/README.md) | 2026-08-01 | Both hosted and self-hosted serve both public and private repositories |
| [0040](0040-runner-lanes-and-admission-axes/README.md) | 2026-08-01 | Lanes name the work; groups enforce admission |
| [0039](0039-required-workflow-gate-provenance/README.md) | 2026-07-31 | Organization required-workflow runs are trusted gate provenance |
| [0038](0038-canonical-changelog-contract/README.md) | 2026-07-30 | Canonical changelog fragments and immutable release snapshots |
| [0037](0037-isolate-actions-write-dispatch/README.md) | 2026-07-30 | Isolate Actions write permission in a metadata-only dispatcher |
| [0036](0036-separate-pr-review-from-privileged-merge/README.md) | 2026-07-30 | Separate PR review from privileged merge authority |
| [0035](0035-variable-driven-runner-lanes/README.md) | 2026-07-30 | Variable-driven runner lanes with a temporary permissive lane |
| [0034](0034-temporary-general-merge-gate/README.md) | 2026-07-29 | Temporarily route Verjson merge gates through general runners |
| [0033](0033-self-hosted-runner-policy-by-visibility/README.md) | 2026-07-29 | Route runners by repository visibility, on configurable self-hosted pools |
| [0032](0032-gate-budget-exceeded-outcome/README.md) | 2026-07-29 | Size the merge-gate review budget to the diff, and make budget exhaustion an explicit blocking outcome |
| [0031](0031-node-ci-isolated-pool-allowlist/README.md) | 2026-07-29 | Route node-ci on isolated-pool admission, not organization ownership |
| [0030](0030-portable-reusable-runner-policy/README.md) | 2026-07-28 | Separate Verjson runner policy from reusable-workflow portability |
| [0029](0029-repurpose-meta-runners-private-gate/README.md) | 2026-07-28 | Repurpose retired meta runners as private merge-gate capacity |
| [0028](0028-runner-security-tiers-cache-boundary/README.md) | 2026-07-28 | CI security tiers and runner-aware npm cache boundaries |
| [0027](0027-pulumi-preview-credential-boundary/README.md) | 2026-07-27 | Pulumi validation and live preview use separate credential boundaries |
| [0026](0026-actionlint-reusable-governed-runners/README.md) | 2026-07-27 | Reusable actionlint offers only governed runner choices |
| [0025](0025-release-tooling-audit-allowlist/README.md) | 2026-07-25 | Release-tooling audit accepts dated, per-advisory exceptions |
| [0024](0024-absent-checks-fail-closed/README.md) | 2026-07-25 | Absent CI checks fail the merge gate closed |
| [0023](0023-skip-ci-while-stability-days-pending/README.md) | 2026-07-24 | Skip org CI while a PR is held by renovate/stability-days |
| [0022](0022-gate-reusable-cross-org/README.md) | 2026-07-23 | Distribute the merge gate as a pinned cross-org reusable workflow |
| [0021](0021-node-ci-caller-supplied-db-image/README.md) | 2026-07-22 | node-ci runs a caller-supplied DB image on the shared self-hosted pool |
| [0020](0020-gate-constrains-dispatch-target-to-org/README.md) | 2026-07-22 | Merge gate constrains its dispatch target to this org |
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

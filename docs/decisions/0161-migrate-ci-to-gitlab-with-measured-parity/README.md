# 0161 — Migrate CI to GitLab with measured parity and reversible cutovers

- **Date:** 2026-09-01
- **Status:** Accepted
- **Issue:** [#1209](https://github.com/Verjson/.github/issues/1209)
- **Superseded by:** [ADR 0162](../0162-unify-portable-ci-engine-and-forge-adapters/README.md)
- **Related:** [#629](https://github.com/Verjson/.github/issues/629),
  [ADR 0040](../0040-runner-lanes-and-admission-axes/README.md),
  [ADR 0123](../0123-use-organization-neutral-ci-variables/README.md)

## Context

Verjson already operates GitLab CE with colocated GitLab Runner capacity. The next
decision is therefore not how to provision GitLab, but how to move suitable CI work
from GitHub Actions to GitLab without weakening required checks, exposing credentials,
or replacing a known-good path before its replacement is proven. The explicit business
goal is to reduce, and where practical eliminate, paid GitHub Actions usage.

This repository currently contains 47 GitHub workflow files. They do not form one
portable workload. Some run ordinary lint, test, and build commands. Others depend on
GitHub reusable-workflow semantics, GitHub Apps, repository and organization APIs,
GitHub Packages, Actions caches and artifacts, OIDC claims, protected environments, or
the merge gate itself. A file-for-file YAML translation would hide those trust and
provider boundaries instead of preserving them.

The deployment safety models are also deliberately separate. GitLab CE is stateful
(database, repository storage, and service data) and requires its own maintenance,
backup, upgrade-hop, restore, and health-verification contract. GitLab Runner execution
capacity is replaceable and can use blue/green runner slots. The DigitalOcean GitHub
Actions runner fleet in #629 remains a third, independent contract. Similar receipts
and rollback principles are useful prior art, but two different topologies and two CI
providers do not justify a shared controller or state machine.

## Decision

Migrate CI by workload class, not by repository or workflow-file count. During the
transition GitHub remains the source-of-truth repository, pull-request authority, and
required-check authority. A GitLab pipeline may become the executor for a required check
only after an immutable commit identity binds the GitLab result back to the exact GitHub
head. Mirroring lag, an ambiguous ref, or a missing status bridge fails closed.

### Workload classes

| Class | Examples | Migration disposition |
| --- | --- | --- |
| Portable, credentialless | formatting, lint, unit tests, type checks, deterministic builds, documentation checks | First candidates. Express the command and toolchain outside provider orchestration, then run the same revision on both providers. |
| Portable with bounded service state | integration tests, caches, test artifacts, service containers | Migrate after cache/artifact provenance, retention, isolation, and cleanup have provider-specific adapters and parity evidence. A cache hit is never correctness evidence. |
| Trusted or secret-bearing | private package acquisition, deployment previews, signed build inputs | Migrate only after an explicit least-privilege credential map, protected-ref admission, masking test, and revocation/rotation runbook. Do not copy all GitHub secrets into GitLab. |
| Privileged or GitHub control plane | merge orchestration, ruleset reconciliation, GitHub App flows, organization audits, GitHub release and Packages operations | Keep on GitHub until a separately reviewed design preserves the GitHub authority and token boundary. Moving ordinary CI does not imply moving these jobs. |
| Stateful GitLab CE operations | GitLab backup, restore, upgrades, database and repository-storage maintenance | Never share the runner blue/green controller. Operate under a maintenance-window and restore-tested service contract. |

### Trust and secret boundaries

The existing lane meanings survive the provider change: untrusted change content,
trusted organization work, and privileged control-plane work remain distinct even if
two classes currently land on the same host. GitLab protected variables and protected
runners must not be available to untrusted merge-request pipelines. Fork and
merge-request jobs receive no package, deployment, mirror-write, or GitHub status-write
credential.

The status bridge is a narrow privileged adapter. It does not trust a receipt, job name,
status, or CI metadata produced by repository code. Before mapping one reviewed GitLab
job to one GitHub check, the bridge uses its own read-only GitLab API credential to verify
the immutable project ID, pipeline and job IDs, exact commit SHA and ref, terminal job
status, and the digest of the CI configuration and included templates actually executed.
That digest must equal the reviewed digest resolved from a trusted configuration revision;
a pipeline sourced from change-authored `.gitlab-ci.yml` cannot authorize a check merely
because it emits the expected job name or a green receipt. Repository-produced receipts
remain comparison data only. The bridge cannot execute repository content with its GitHub
credential. Provider-native job tokens stay provider-local. Cross-provider tokens have
one purpose, minimal repository scope, short lifetime where supported, and independent
rotation and revocation procedures. OIDC trust must bind issuer, audience, project,
protected ref, and job identity; claims from GitHub and GitLab are not interchangeable.

Runner and GitLab CE isolation is an operational requirement even when colocated.
Untrusted jobs use disposable workspaces, receive no host socket or GitLab service
credentials, and cannot read another job's cache or the GitLab CE data volumes. A runner
compromise must not imply GitLab administrator or backup access.

### Parity and authority gates

A candidate lane dual-runs the same immutable commit with the same lockfiles, pinned
toolchain, test selection, environment contract, and timeout. Its normalized receipt
records provider, repository, commit SHA, workload-contract version, command set,
conclusion, duration, retry count, and artifact digests where deterministic. Secrets and
provider tokens never enter the receipt.

Parity means more than both providers returning green. Before a class can cut over:

1. every expected job reaches a terminal result and no job is silently skipped;
2. success, failure, cancellation, timeout, and deferred/no-op outcomes map identically;
3. deliberately injected failures are rejected by both providers;
4. deterministic artifacts have equal digests, or reviewed nondeterministic fields are
   normalized and the remaining payload is equal;
5. negative tests prove a same-named job and a change-authored or modified
   `.gitlab-ci.yml` cannot forge an authoritative green check;
6. branch protection still binds the result to the exact GitHub head; and
7. the observation window meets the documented reliability and cost thresholds in the
   migration plan.

GitLab results are advisory during shadow mode. They become required only in a canary
repository or workload after the parity gate passes. A GitHub check is not removed in
the same change that first makes its GitLab replacement authoritative.

### Phased cutover and rollback

The migration has five phases: baseline, shadow dual-run, canary authority, class
cutover, and retirement. Each phase has an immutable inventory, an owner, measured
entry and exit criteria, and a rollback switch. Canary selection starts with a low-risk,
credentialless workload that exercises the common toolchain; it does not start with a
release, merge, deployment, or organization-admin job.

Rollback restores the last verified GitHub execution route for that workload class. The
GitHub definition and its required-check mapping remain runnable through the observation
window; rollback never rebuilds or edits the failed GitLab pipeline in place. A parity
regression, elevated failure or queue rate, stale mirror, incorrect check binding,
credential-boundary violation, or total-cost regression triggers rollback. GitLab CE
service rollback and GitLab Runner slot rollback remain separate operations.

### Cost objective and exit criteria

Measure cost per successful workload and per merged change, not Actions minutes alone.
The ledger includes GitHub-hosted billed minutes by OS and repository visibility,
self-hosted GitHub runner infrastructure, GitLab runner compute, incremental GitLab CE
storage/backup/egress, operator time, retries, and dual-run overhead. Public standard
Linux Actions minutes may be zero-cost; moving them first can increase total cost without
advancing the spending goal, so prioritization follows measured avoidable spend.

A workload class exits dual-run only when its GitLab route is at least as reliable,
meets its queue and duration service levels, preserves all trust and required-check
properties, and shows a lower projected total cost over the agreed measurement window.
The migration is complete when all economically justified portable classes use GitLab by
default, remaining GitHub jobs have a documented provider-specific reason, paid GitHub
Actions usage is at the approved floor for two consecutive billing periods, and rollback
has been exercised. “Zero GitHub spend” is a target, not permission to move a privileged
job across an unproven boundary or to hide costs in the GitLab host.

## Consequences

- GitHub and GitLab intentionally coexist during migration; duplicate execution is a
  temporary measurement cost with a recorded end date per workload class.
- Portable command contracts become the reusable seam. Provider YAML remains thin
  orchestration, but no speculative universal CI controller is introduced.
- GitHub-coupled control-plane work can remain on GitHub even after most compute moves.
  Each exception is visible in the inventory and cost ledger rather than treated as a
  failed migration.
- GitLab CE maintenance, GitLab Runner blue/green operations, and #629's GitHub runner
  fleet keep separate controllers, credentials, receipts, and rollback gates.
- Live mirroring, runner registration, required-check mutation, secret writes, and
  infrastructure changes require their own reviewed implementation and operator gates;
  this ADR authorizes none of them.

## Verification

The implementation plan is maintained in
[`docs/gitlab-ci-migration.md`](../../gitlab-ci-migration.md). Each cutover PR must attach
the exact-head dual-run receipts, negative-path parity evidence, cost comparison, current
required-check readback, secret-boundary review, and a successful rollback rehearsal.

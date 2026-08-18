# 0109 — Observe-first Renovate compatibility control plane

- **Date:** 2026-08-18
- **Status:** Accepted
- **Issue:** [#699](https://github.com/Verjson/.github/issues/699)
- **Depends on:** [`Verjson/renovate-config` ADR 0005](https://github.com/Verjson/renovate-config/tree/main/docs/decisions/0005-compatibility-control-plane)

## Context

Repository CI can prove that a major dependency candidate breaks a supported
interface, but a repository-local ignore loses that evidence and can suppress a
package for unrelated stacks. Repeating the same investigation in every repository
also consumes CI and AI-review capacity.

The organization policy repository now supplies a validated, stack-scoped hold
registry and deterministic grouping planner. The organization automation boundary
must consume that policy without allowing a red or flaky pull request to create a
hold, and it must continue probing newer candidates while ordinary rollout is held.

This automation reads cross-repository checks and executes candidate repository code.
Those are separate trust boundaries: observation needs organization read access, while
candidate execution must receive no organization, package, publication, or cloud
credential.

## Decision

Adopt an observe-first control plane:

1. A daily/manual reconciler inventories failing Renovate pull requests with compact
   GitHub projections. It emits an immutable report whose candidates require a
   controlled retry. It has no issue, pull-request, or contents write grant and cannot
   create a compatibility hold.
2. The decision engine accepts a fingerprint only when the default branch is green,
   the candidate is a major update, the relevant check fails, and a controlled retry
   produces the same normalized signature. Its identity is ecosystem, package,
   target major, stack profile, and signature. A second occurrence reuses the first
   classification.
3. Holds remain human-reviewed data in `Verjson/renovate-config`. Candidate discovery
   deliberately ignores the ordinary rollout hold and selects versions newer than
   `testedThrough` for every representative repository.
4. Candidate canaries run on the untrusted lane, use a read-only checkout without
   persisted credentials, install with lifecycle scripts disabled, and receive no
   secrets. They may run only the bounded build, typecheck, and test scripts and upload
   no authoritative evidence themselves. A separate credentialless control job on the
   isolated trusted lane authors the machine-readable receipt from trusted workflow inputs,
   the caller ref/SHA, the fixed command contract, and `needs.canary.result`.
5. Consumer callers are generated and bind the reusable workflow to one immutable
   contract SHA. Handwritten callers are non-conforming.

The first rollout remains report-only. Automatic issue creation, hold mutation,
hold-removal pull requests, and Renovate rollout are not authorized until receipts
demonstrate the acceptance criteria. Existing merge-gate ordering already waits for
required CI before model execution; a compatibility check becomes required only after
consumer rollout proves its availability, preventing a fleet-wide absent-check outage.

## Consequences

- Red bases, flaky failures, and unrelated stack profiles cannot quarantine a release.
- Candidate code cannot push, publish, deploy, or obtain protected credentials.
- The dedicated compatibility App needs repository metadata, contents, pull-request,
  checks/status, and Actions read permissions only during this phase. No write
  permission is required.
- Operators can roll back by disabling the scheduled workflow. Existing Renovate
  behavior and holds remain unchanged because observe-only automation makes no policy
  mutation.

## 2026-08-18 authentication-boundary clarification

The observe-first workflows authenticate with the dedicated compatibility App's client
ID and private key. Each mint further narrows the installation token to the exact call
surface: the reconciler receives `contents`, `pull-requests`, `checks`, and `statuses`
read permissions; the grouping planner receives only `contents: read`. Neither token
has mutation authority.

The grouping planner runs on the trusted lane because minting the App token introduces
a protected private key. It checks out the private policy repository at the immutable
reviewed commit recorded in the workflow, passes the short-lived token only to that
checkout, and sets `persist-credentials: false`. Candidate code remains confined to the
credentialless untrusted canary lane; this clarification does not authorize automatic
issues, holds, policy changes, or Renovate rollout.

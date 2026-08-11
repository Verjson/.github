# 0091 — Require the authorization arm, not the dispatched AI review

- **Date:** 2026-08-10
- **Status:** Accepted
- **Issue:** [#728](https://github.com/Verjson/.github/issues/728)
- **Amends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md), [ADR 0090](../0090-human-first-opt-in-ai-review/README.md)

## Context

Organization ruleset `main-protection` (`18098028`) selects
`.github/workflows/ai-review-merge.yml@main` as its one required workflow. GitHub
ruleset workflows run only when their source declares `pull_request`,
`pull_request_target`, or `merge_group`. The selected review workflow deliberately
declares only `workflow_dispatch` and `workflow_call`, because ADR 0079 requires an
immutable exact-head arm receipt before review can gain authority. A consumer PR can
therefore synchronize without a ruleset workflow run, receipt, dedicated-App check,
review, or terminal promotion.

The trusted `gate-rearm.yml` entrypoint already declares `pull_request_target`, never
checks out PR code, creates the exact-head App check and receipt, and dispatches the
review only after the artifact is published. GitHub ignores a ruleset workflow's event
filters and invokes the default `pull_request_target` activity types: `opened`,
`synchronize`, and `reopened`. Repository-local callers remain responsible for label-only
events such as adding `ai-review`; the organization rule guarantees that the next
supported PR synchronization reaches the arm.

Required workflows execute in the governed repository's context. The App private key
and identity variables are currently selected to fewer repositories than the ruleset's
`~ALL` scope. Retargeting first would make the arm unable to mint the dedicated App token
in those repositories. Requiring both the retired workflow and an App check would be
worse: one never starts and the other never appears.

## Decision

Change the one workflow selected by `main-protection` from
`.github/workflows/ai-review-merge.yml@main` to
`.github/workflows/gate-rearm.yml@main` in a single ruleset update. Never retain both
paths, and do not also require `AI review authorization` as a status context.

The arm job is `continue-on-error`: its failures remain visible, but the required
workflow cannot veto a merge authorized by the existing human review and deterministic
CI policy. This does not weaken AI authority. App approval and terminal promotion still
require the exact successful dedicated-App check, immutable receipt, reviewed head,
policy envelope, and configured deterministic CI. A missing receipt or failed arm grants
nothing.

`scripts/ai-review-required-workflow-audit.py` is the mandatory read-only preflight and
post-change verifier. It fails unless:

- `main-protection` has the reviewed `~ALL` scope and exactly one recognized workflow;
- no other organization ruleset requires either arm identity or the App check;
- the private key and App identity variables reach every currently governed repository;
- the dedicated App installation is unsuspended, covers all repositories, and retains
  Checks write, contents read, and pull requests write; and
- canonical `gate-rearm.yml@main` exposes `pull_request_target` while keeping the arm
  non-blocking for ADR 0090's human path.

Rollout order is strict: merge the workflow, contract, and audit; obtain separate human
authorization for any secret or variable scope expansion; run the audit until it reports
`state=ready`; replace the one ruleset workflow path; then run the audit again until it
reports `state=retargeted`. On a controlled same-repository PR head carrying `ai-review`,
force a synchronization and verify the ruleset-created arm run, immutable receipt,
exact-head App check, App review, immutable privileged caller dispatch, and terminal
promotion waiting on ordinary required CI. The rollout is incomplete until that live
proof exists.

## Consequences

- A supported PR event reaches the trusted arm instead of silently selecting a workflow
  that cannot start.
- AI remains opt-in and non-vetoing; a human can merge through ordinary policy during a
  provider or authorization outage.
- The currently incomplete credential scope is a measured rollout blocker, not an
  implicit request to expose the private key organization-wide.
- Rollback is the inverse single-path replacement after the old workflow has first been
  restored to a ruleset-supported, human-nonblocking entry surface. Removing the arm
  before that proof would recreate this incident and is forbidden.

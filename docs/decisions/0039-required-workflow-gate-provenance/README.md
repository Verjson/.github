# 0039 — Organization required-workflow runs are trusted gate provenance

- **Date:** 2026-07-31
- **Issue:** [Verjson/.github#259](https://github.com/Verjson/.github/issues/259)
- **Extends:** ADR 0036 (attestation-bound continuation) and ADR 0037 (isolated dispatcher)

## Context

ADR 0036 made the privileged merge trust exactly one thing: a bounded attestation
artifact produced by a gate run it can prove is the org's `ai-review-merge.yml`. The
implementation recognised two installation shapes — this repository running the
workflow itself (`workflow_id` equality) and a consumer calling it as a reusable
workflow (`referenced_workflows[].path` pinned to the trusted repository at the
current `main` SHA).

Verjson does not install the gate either way. The organization ruleset
`main-protection` carries a `workflows` rule mandating
`Verjson/.github/.github/workflows/ai-review-merge.yml@refs/heads/main`. A run of that
shape lives in the consumer repository with a repository-scoped `workflow_id`, an empty
`referenced_workflows`, and a `workflow_url` under `/actions/required_workflows/`.
Neither matcher fires, so `provenance` never reached `trusted`, and every privileged
run exhausted its bounded wait with `trusted gate/checks did not become green` —
`pull_request_target` and dispatched runs alike.

The dispatcher compounded this. It hands the privileged workflow its own gate run in
`source_run_id`, but the receiving check required that run's `event` to be
`workflow_dispatch`. The gate is triggered by `pull_request`, so the dispatched path
could never validate its source even in the shapes that were recognised.

The observable end state was the one reported on #259: gate and dispatch-merge green,
the `pull_request_target` `privileged_merge` check cancelled by the dispatched run's
concurrency group, the dispatched run failing on `main` where it publishes no check,
and consumer pull requests parked OPEN/BLOCKED with nothing left running.

## Decision

An organization-ruleset **required workflow** run is a third recognised trusted gate
provenance shape, on these conditions, all of which must hold:

- the run's `workflow_url` is a `/actions/required_workflows/<id>` URL, and its `path`
  is the trusted `.github/workflows/ai-review-merge.yml`;
- the pull request's **base branch** rules — read across *all* pages, since the endpoint
  paginates — include a `workflows` rule mandating that path, and **every** such rule at
  that path names the trusted repository id at `refs/heads/main` and originates from an
  `Organization` ruleset owned by the target owner.

The organization ruleset is the trust anchor. A repository administrator can add a
repository-level ruleset, but cannot mint an `Organization`-sourced one, so a same-path
impostor rule visible in that read withdraws required-workflow trust rather than letting
it be inherited. Absent, empty, partially readable, or non-array rule payloads leave the
shape untrusted and fall back to the two existing matchers.

Because the anchor is ambient configuration rather than a property of the run itself, it
is resolved twice: once before the wait loop and again immediately before merging, on a
base branch asserted to be unchanged. That bounds — but does not eliminate — the window
in which a repository administrator could install a required workflow, let it produce an
impostor run at the pull-request head, and remove the rule before the merge check reads
it. Closing that window durably requires binding provenance to the producing workflow
identity (a signed attestation verified with `--signer-workflow`) rather than to
configuration read after the fact; that is tracked in
[#261](https://github.com/Verjson/.github/issues/261) and is not part of this decision.

The dispatched continuation validates its `source_run_id` against the same predicate,
accepts the events the gate actually runs on (`pull_request` and the manual
`workflow_dispatch` re-gate), and additionally requires the source run to be bound to
the expected head SHA.

A pull request already merged at the verified expected head is a terminal success for
the privileged run, not a failure. Head equality is asserted before the state check, so
this settles the benign race between the `pull_request_target` run and its dispatched
replacement without accepting any other non-open state.

## Consequences

- Consumers that receive the gate through the organization ruleset can complete
  privileged auto-merge; previously none could.
- The trusted set grows by exactly one shape, anchored on organization-level
  configuration rather than anything a repository or a pull request controls.
- Head/attestation/hold/draft/workflow-file guards, the `ORG_ADMIN_TOKEN` boundary, and
  the dispatcher's `actions: write` isolation from ADR 0037 are unchanged.
- One additional read-only API call per privileged run resolves the base-branch rules.
- `scripts/ci-gate/required-workflow-provenance.test.sh` pins the contract against the
  shipped workflow body: each clause of the anchor is pinned by its own rejection case,
  including an impostor rule sitting *beside* a valid one and an impostor on a later
  rules page, and every negative case asserts the specific terminal error so it cannot
  pass by failing elsewhere.
- The residual trust window above is the known limit of this design, not an oversight.

## Rollback

Revert the implementing PR. Consumers then return to requiring human merge on every
pull request. Do not instead widen the predicate to accept a required-workflow run on
`path` alone: without the organization-ruleset anchor, a repository-level ruleset could
nominate an arbitrary source workflow at the same path, and the run object carries no
source-repository identity of its own to fall back on.

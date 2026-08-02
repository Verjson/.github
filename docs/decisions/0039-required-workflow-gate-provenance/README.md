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
`main-protection` (id `18098028`) carries a `workflows` rule mandating
`.github/workflows/ai-review-merge.yml` at `refs/heads/main` from `repository_id`
`1269388380` — `Verjson/.github`. A run of that shape lives in the consumer repository
and looks like this; the values are transcribed from `Verjson/verjson-cloud-storage`
run `30601252875`, recorded here because the ADR outlives the issue thread that
observed it:

```
workflow_id:           318934643      # repository-scoped, not the org workflow id 312358392
referenced_workflows:  []
path:                  .github/workflows/ai-review-merge.yml
workflow_url:          https://api.github.com/repos/<consumer>/actions/required_workflows/318934643
event:                 pull_request
```

Neither matcher fires, so `provenance` never reached `trusted`, and every privileged
run exhausted its bounded wait with `trusted gate/checks did not become green` —
`pull_request_target` run `30594009367` and dispatched run `30601445365` alike.

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

## Amendment — 2026-08-02: the gate identifies its own checks by provenance

Refs [Verjson/.github#276](https://github.com/Verjson/.github/issues/276).

Trusting the reusable-call shape for *provenance* was not enough to make it
usable. A reusable `workflow_call` publishes the callee's checks as
`<caller job> / <callee job>`, and both CI snapshots in `ai-review-merge.yml`
filtered the required set by exact equality against a static list of bare job
names. A consumer installing the gate with `uses:` therefore had the gate's own
`ci / preflight`, `ci / gate` and `ci / dispatch-merge` counted as required
checks: the gate waited on itself until the poll window expired and reported
`trusted gate/checks did not become green`, a message pointing nowhere near the
cause. Verjson never saw it because the organization ruleset installs the gate as
a required workflow, which publishes un-prefixed names, and no repository in the
organization used the `uses:` shape.

Both snapshots now read `repos/<repo>/actions/runs/<run id>/jobs` and take the
names GitHub actually published for this run — prefixed or not, whichever shape
is installed. This keeps the identification of "the gate's own checks" anchored
on run provenance, the same principle this ADR applies to merge provenance.

Two properties are load-bearing and are pinned by
`scripts/ci-gate/self-job-exclusion.test.sh`:

- **Not name normalization.** Stripping everything before `/` keys on the callee
  segment, so an unrelated consumer check named `security / review` or
  `release / gate` would silently drop out of the required set — a fail-open in
  someone else's repository. Provenance cannot over-match; a substring rule can.
- **A union, not a replacement.** Jobs are created as they start, so a run cannot
  enumerate its own not-yet-created `dispatch-merge`/`ai-merge` jobs. The static
  list remains the floor, alongside the trusted-continuation literal.

An unreadable or unparseable jobs API is inconclusive: the exclusion set stays at
the static floor and the step warns. Failing to derive names never widens what is
excluded, so the worst case is the pre-existing behaviour, never a fail-open.

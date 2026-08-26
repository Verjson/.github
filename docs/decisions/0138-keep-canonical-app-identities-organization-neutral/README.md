# 0138 — Keep canonical GitHub App identities organization-neutral

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1086](https://github.com/Verjson/.github/issues/1086)
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md)
- **Extends:** [ADR 0119](../0119-restore-dedicated-app-for-renovate-observation/README.md)
- **Extends:** [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)
- **Extends:** [ADR 0136](../0136-separate-dependency-supersession-observation-from-mutation/README.md)

## Context

Canonical CI is consumed outside the Verjson organization. GitHub App names and slugs
that include the source organization create a misleading adopter contract and encourage
organization-specific configuration. On 2026-08-25 the existing Apps were renamed to
neutral identities. Renaming did not change the App or installation identities,
repository selection, permissions, webhook subscriptions, credentials, or ruleset
bypass actors.

The AI authorization rename exposed a failure mode in the trusted arm. Its configured
slug still named the former App identity. The arm minted the correct App token, created
an `in_progress` authorization check, and only then rejected the check response's slug.
Because the failed assertion did not complete the created check, affected pull requests
were left permanently pending rather than visibly failed.

## Decision

The live organization-neutral App identities are:

| Purpose | Canonical slug | App ID | Installation ID | Repository permissions |
|---|---|---:|---:|---|
| AI review authorization | `ai-review-authorization` | 4528902 | 152248101 | Checks: write; Contents: read; Pull requests: write; Metadata: read |
| Renovate compatibility observation | `renovate-compatibility` | 4693151 | 155974622 | Actions: read; Checks: read; Contents: read; Pull requests: read; Commit statuses: read; Metadata: read |
| Terminal merge authorization | `merge-authorization` | 4693283 | 155977749 | Contents: write; Pull requests: write; Metadata: read |
| Dependency supersession reconciliation | `canonical-dependency-supersession` | 4717539 | 156593170 | Contents: read; Pull requests: write; Metadata: read |
| Release authorization | `release-authorization` | 4583107 | 153483031 | Contents: write; Metadata: read |

All five installations select all repositories, are unsuspended, request no
organization permissions, and subscribe to no events or webhooks. Renaming must never
be used as a reason to recreate an App, rotate its credentials, widen its permissions,
change its installation scope, or alter its ruleset bypass authority.

Canonical executable fixtures use the current neutral slugs. Immutable historical ADR
and changelog statements retain the names that were true when recorded; this ADR is the
dated superseding identity record.

App ID 4583107 retains `always` bypass on all five active organization rulesets:
`main-protection` (18098028), `changelog-contract-required` (20513599),
`core-checks-node` (20515817), `core-checks-actions` (20515822), and
`ai-authorization-arm-required` (20722935). No other bypass change is authorized.

Before creating an authorization check, the arm compares the token-mint action's
reported App slug with `AI_REVIEW_APP_SLUG`. A missing, malformed, or inconsistent slug
emits one exact error and fails before the authorization-check POST, so the rename
mismatch that caused #1086 cannot create a new pending check. The App identity is rooted
in the reviewed private key and client ID passed only to the immutable
`actions/create-github-app-token` action; its `app-slug` output is the independently
compared runtime identity signal.

> **2026-08-25 correction:** The first implementation additionally called
> `GET /installation` with the minted installation token. Production
> [run 32911395973, job 98006134512](https://github.com/Verjson/.github/actions/runs/32911395973/job/98006134512)
> proved GitHub returns 404 for that authentication mode, blocking the legitimate App
> before check creation. The inaccessible probe is removed. Installation/App-ID
> continuity remains a live administrative audit assertion, not an installation-token
> runtime capability. This correction narrows the executable preflight without changing
> App permissions, credential delivery, or the exact action-reported slug comparison.

The authorization-check POST is the next identity boundary. Once its response supplies
a positive numeric check ID, the arm publishes that ID as a step output before checking
the response App ID, slug, and receipt external ID. A mismatch still fails the arm, but
the always-run no-dispatch terminalizer can then read the created check and PATCH an
`in_progress` result to `completed`/`failure`. This ordering preserves the immutable
token-action, private-key, and client-ID trust boundary while ensuring response
attribution failures cannot strand a required check.

The one-time #1086 recovery bootstrap is deliberately narrower than the cross-run
reconciler tracked in #1094. GitHub's
[required-workflow rule schema](https://docs.github.com/en/rest/repos/rules#update-a-repository-ruleset)
supports an exact `sha` in addition to its branch or tag `ref`; the `sha` is the immutable
execution binding. The reviewed workflow revision is
`f7854f161dab66f00d600adbc0aaa2fb5e874b65`. A later PR-head commit that changes only this
ADR does not replace that workflow identity: before bootstrap, require
`git diff --exit-code f7854f161dab66f00d600adbc0aaa2fb5e874b65..<reviewed-pr-head> --
.github/workflows/gate-rearm.yml` to prove the workflow is byte-identical.

An authorized administrator must execute this exact fail-closed sequence:

1. Save the complete JSON preimage of organization ruleset 20722935. Assert it contains
   exactly one canonical tuple `{path: .github/workflows/gate-rearm.yml, repository_id:
   1269388380, ref: refs/heads/main}` and record its conditions, rules, enforcement, and
   bypass actors for later exact restoration.
2. Before creating `refs/heads/bootstrap/1096-gate-rearm-f7854f1`, create an active,
   repository-scoped temporary ruleset whose only condition is that exact ref, whose rules
   are `creation`, `update` with `update_allows_fetch_and_merge: false`, and `deletion`,
   and whose only bypass actor is `OrganizationAdmin` in `always` mode. Do not copy
   integration, user, or team bypasses into it and do not add any actor to ruleset
   20722935. Read the temporary ruleset back and require exact equality before an
   administrator creates the branch at `f7854f161dab66f00d600adbc0aaa2fb5e874b65`.
3. Read the Git ref back and require that exact SHA. Then update only ruleset 20722935's
   canonical workflow tuple to `{path: .github/workflows/gate-rearm.yml, repository_id:
   1269388380, ref: refs/heads/bootstrap/1096-gate-rearm-f7854f1, sha:
   f7854f161dab66f00d600adbc0aaa2fb5e874b65}`. Read back both rulesets and reject any
   difference from the saved preimage other than this tuple's `ref` and added `sha`.
4. Immediately before every fresh-check trigger, re-read and assert all three anchors:
   the bootstrap Git ref still equals `f7854f...`, its temporary ruleset remains active
   with the exact condition/rules/single admin bypass, and the organization workflow tuple
   still carries both the exact bootstrap `ref` and `sha: f7854f...`. Record the ruleset
   history version, read-back timestamp, trigger timestamp, and pre-trigger run IDs.
5. For every green run accepted as satisfying the required workflow, bind the run to that
   tuple programmatically. The run must be `completed/success`, have event
   `pull_request_target`, exact PR head SHA, path `.github/workflows/gate-rearm.yml`, and a
   consumer-scoped `workflow_url` under `actions/required_workflows/`. At the same time,
   `GET /repos/Verjson/.github/rules/branches/main` must expose exactly one matching
   organization workflow selector with canonical repository ID, bootstrap `ref`, and
   `sha: f7854f...`. Each accepted run ID must be absent from the pre-trigger set and its
   `created_at` must follow the recorded rule read-back and trigger. GitHub's run REST
   object reports the PR commit as `head_sha`; never misread that as
   `github.workflow_sha`. The rule selector's read-back `sha` is the platform-enforced
   workflow SHA. An absent or different `sha`, stale run ID or timestamp, ambiguous
   matching rule, mutable ref, unprotected ref, or unmatched run rejects the run
   regardless of green.
6. Merge only if step 5 accepts every required-workflow run and
   `[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")`
   prints the literal value `true` for the exact reviewed PR head.
7. After merge, keep the temporary protection active. Resolve the new `main` tip, require
   `git diff --exit-code f7854f161dab66f00d600adbc0aaa2fb5e874b65..<new-main-tip> --
   .github/workflows/gate-rearm.yml`, and
   change the canonical tuple to `ref: refs/heads/main` plus `sha: <new-main-tip>`. Read
   that tuple back, trigger a fresh canary PR, and apply the provenance, freshness, and
   literal-green assertions from steps 4–6 with the main ref and exact main SHA
   substituted. Do not merge the canary. This proves a fresh main-sourced arm rather than
   accepting a stale bootstrap run.
8. Only after the main-sourced canary is terminal green, restore ruleset 20722935 byte for
   byte from its saved preimage and read it back. With the temporary ruleset still active,
   delete the bootstrap branch through the existing `OrganizationAdmin` bypass and prove
   the ref is absent. Delete the temporary ruleset last and prove it is absent. This order
   prevents non-admin update, deletion, or recreation throughout the recovery window.

Any failed assertion stops the sequence without merging, weakening a ruleset, widening a
bypass list, removing temporary protection, or deleting evidence needed for diagnosis.

This PR records but does not perform that live ruleset mutation or bootstrap.

Recovery of a check orphaned after this preflight—for example, a later process loss or
an accepted API mutation whose response is lost—requires a cross-run reconciliation
contract and is deliberately deferred to [#1094](https://github.com/Verjson/.github/issues/1094).
This ADR does not claim that same-run cleanup proves recovery across runner or workflow
termination boundaries.

## Trust boundaries

- Numeric App and installation identities, not mutable display names, preserve
  continuity across a rename.
- A configured slug is still checked because downstream bot-login and check-attribution
  assertions bind to it; disagreement is a configuration or authentication failure.
- The pinned token action's slug output is checked before mutation. The installation
  token is not assumed to authorize App-configuration discovery endpoints.
- The App token remains repository-scoped and permission-scoped according to its
  controlling ADR. This decision grants no new capability.
- No authorization check is created when the minted App identity disagrees with the
  configured identity. Any App-attribution mismatch returned by the creation API is
  terminalized as failure. Later cross-run orphan recovery remains outside #1086.

## Consequences

Adopters configure meaningful neutral App identities. A future rename is a reviewed
configuration migration with an explicit dated record. Slug drift becomes a precise red
failure instead of a silent job error or an indefinitely pending authorization check.

## Rollback

Restore the last reviewed neutral slug variable only when it still resolves to the same
numeric App and installation and live permissions remain exact. Do not recreate an App
or restore an organization-prefixed name as a workflow rollback.

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
reconciler tracked in #1094. An authorized administrator must:

1. Record PR #1096's independently reviewed head SHA, create a temporary bootstrap branch
   whose ref resolves to exactly that SHA, and reject the procedure if either ref moves.
2. Temporarily change only organization ruleset 20722935's required workflow tuple
   `{path: .github/workflows/gate-rearm.yml, repository_id: 1269388380, ref:
   refs/heads/main}` so its `ref` names that bootstrap branch; no bypass, actor,
   enforcement, path, repository ID, or other required-workflow setting may change.
3. Trigger fresh checks for PR #1096 and merge only after
   `[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")`
   prints the literal value `true` for that exact head.
4. Restore the required workflow ref to `refs/heads/main`, read the ruleset back to prove
   the restoration, then trigger a fresh canary and require the same literal all-green
   assertion with the gate sourced from `main`.
5. Delete the bootstrap branch only after both restoration and canary evidence are
   durable. Any failure stops the sequence without merging, widening bypass, or deleting
   the branch needed for diagnosis.

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

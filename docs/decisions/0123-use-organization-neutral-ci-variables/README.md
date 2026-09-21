# 0123 — Use organization-neutral canonical CI variables

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1035](https://github.com/Verjson/.github/issues/1035)
- **Category:** CI routing, policy, and organization configuration (sensitive class)
- **Extends:** [ADR 0041](../0041-indirect-runs-on-through-org-variables/README.md), [ADR 0118](../0118-route-private-terminal-merge-to-hosted-capacity/README.md)

## Context

Canonical reusable workflows and generated callers expose GitHub Actions
configuration through `vars.VERJSON_*`. Those names describe the organization
that authored the contract rather than the routing or policy value they carry.
An adopter in another organization should not need to create configuration
variables named after Verjson, and organization-branded names make otherwise
portable generated artifacts appear organization-bound.

The prefix is used by several different kinds of data. GitHub `vars.*` are the
portable configuration contract. Secrets, internal process environment
variables, package identifiers, and explicit repository-owner comparisons are
different trust boundaries and must not be renamed merely because their text
also contains `VERJSON`.

Immutable historical workflow pins cannot be edited. Removing the existing
organization variables at the same time as the canonical rename would break
old callers that remain valid and reproducible.

## Decision

Every consumer-facing GitHub Actions configuration variable used by canonical
CI moves to a neutral `CI_*` name while preserving its suffix and meaning:

| Previous name | Canonical name |
| --- | --- |
| `VERJSON_LANE_FALLBACK` | `CI_LANE_FALLBACK` |
| `VERJSON_LANE_PRIVILEGED` | `CI_LANE_PRIVILEGED` |
| `VERJSON_LANE_TRUSTED` | `CI_LANE_TRUSTED` |
| `VERJSON_LANE_TRUSTED_MACOS` | `CI_LANE_TRUSTED_MACOS` |
| `VERJSON_LANE_TRUSTED_WINDOWS` | `CI_LANE_TRUSTED_WINDOWS` |
| `VERJSON_LANE_UNTRUSTED` | `CI_LANE_UNTRUSTED` |
| `VERJSON_PACKAGE_RETENTION_KEEP` | `CI_PACKAGE_RETENTION_KEEP` |
| `VERJSON_RUNNER_DEFAULT` | `CI_RUNNER_DEFAULT` |
| `VERJSON_RUNNER_FASTLANE` | `CI_RUNNER_FASTLANE` |
| `VERJSON_RUNNER_GENERAL_GROUP` | `CI_RUNNER_GENERAL_GROUP` |
| `VERJSON_RUNNER_ISOLATED` | `CI_RUNNER_ISOLATED` |
| `VERJSON_RUNNER_OVERFLOW` | `CI_RUNNER_OVERFLOW` |
| `VERJSON_RUNNER_UNTRUSTED` | `CI_RUNNER_UNTRUSTED` |
| `VERJSON_RUNNER_UNTRUSTED_GROUP` | `CI_RUNNER_UNTRUSTED_GROUP` |
| `VERJSON_SECRETLESS_AUXILIARY_POLICY` | `CI_SECRETLESS_AUXILIARY_POLICY` |
| `VERJSON_SECRETLESS_PACKAGE_POLICY` | `CI_SECRETLESS_PACKAGE_POLICY` |
| `VERJSON_WATCHDOG_DRY_RUN` | `CI_WATCHDOG_DRY_RUN` |
| `VERJSON_WATCHDOG_POLL_STEP_DRY_RUN` | `CI_WATCHDOG_POLL_STEP_DRY_RUN` |

The same portability rule applies to GitHub secret names exposed by canonical
workflows and generators:

| Previous name | Canonical name |
| --- | --- |
| `VERJSON_RUNNER_DEPLOY_TOKEN` | `RUNNER_DEPLOY_TOKEN` |
| `VERJSON_RELEASE_TOKEN` | `RELEASE_TOKEN` |

GitHub App credential contracts are already named for their role
(`AI_REVIEW_*`, `MERGE_APP_*`, `RELEASE_APP_*`, and
`RENOVATE_COMPATIBILITY_*`). Their live App slugs, IDs, and installation
identities are operator configuration rather than portable variable names and
do not change. Internal masked process variables such as `VERJSON_GIT_TOKEN`
are implementation details behind neutral action inputs and are not GitHub
configuration contracts.

The macOS and Windows lane names are included because the canonical hosted
selector policy recognizes them even when no current reusable workflow selects
them. Mutation-only invalid names such as `VERJSON_RUNNER_PRIVILEGED` are not a
configuration contract and receive no replacement.

Before canonical workflows switch, the Verjson organization receives `CI_*`
aliases for every currently configured value with identical visibility and
repository selection. Unset optional variables remain unset so their existing
fallback behavior does not change.

Canonical workflows, generators, emitted contract tests, routing policy,
fixtures, reconciler APIs, and documentation use only the neutral names after
the switch. Exact `github.repository_owner == 'Verjson'` checks remain where
they distinguish the operator's private runner fleet from portable hosted
fallbacks.

Legacy `VERJSON_*` organization variables remain available for immutable
historical pins. They may be deleted only after a live inventory proves no
active workflow or generated caller still references them. New canonical code
must not fall back to the legacy names: doing so would silently preserve the
branded public contract.

## Consequences

- New adopters configure semantically named `CI_*` variables independent of
  organization identity.
- Verjson runner routing remains byte-for-byte equivalent at migration because
  the live aliases carry equal JSON selectors.
- Historical pinned callers keep working during the bounded retirement period.
- Tests distinguish GitHub configuration variables from unrelated secrets and
  process environment variables, preventing an indiscriminate textual rename.
- Generated callers must be regenerated at one immutable post-decision SHA;
  hand-edited substitutes are non-conforming.

## Verification

Conformance scans reject `vars.VERJSON_*` from canonical workflows, actions,
generators, emitted artifacts, and hosted-selector policy fixtures. Live API
projections compare each configured old/new pair's value and visibility before
and after merge. The existing routing, admission, secretless, retention,
watchdog, changelog, and generated-caller suites prove the suffix-preserving
rename does not alter behavior. Managed callers are regenerated at one
immutable contract SHA and merged only after exact terminal-green checks.

# 0153 — Bind cli-projects package-surface enforcement to a required workflow

- **Date:** 2026-08-29
- **Status:** Accepted
- **Issue:** [#1177](https://github.com/Verjson/.github/issues/1177)

## Context

`Verjson/verjson-cli-projects` ruleset `21567958` identifies its package-surface
evidence only by the `package-surface-contract` context and the GitHub Actions App.
The ruleset is in `evaluate` because no producer exists on `main`, but a future
repository-owned producer would still be replaceable by the pull request whose package
surface it attests. Matching a display name and App identity does not prove protected
verification code ran.

The verifier must inspect and exercise package bytes supplied by an untrusted pull
request. It also evaluates workflow templates shipped to new repositories. Running that
work on persistent runners or alongside credentials would let candidate code retain or
exfiltrate organization capability.

## Decision

Create `.github/workflows/cli-projects-package-surface-required.yml` as an
organization-owned required workflow. A dedicated active organization branch ruleset
selects repository ID `1277452690`, `~DEFAULT_BRANCH`, canonical workflow repository ID
`1269388380`, the exact workflow path, `refs/heads/main`, and its reviewed immutable
merged SHA. It has no bypass actors and cannot apply to a similarly named repository or
property assignment.

The workflow runs only for `pull_request` and refuses repositories other than
`Verjson/verjson-cli-projects`. It uses `ubuntu-24.04`, grants only contents read, passes
no secrets, and disables persisted checkout credentials. The candidate tree and policy
tree are checked out separately. The policy checkout uses `github.workflow_sha`, binding
the verifier bytes to the same immutable required-workflow revision selected by the
organization rule. Candidate code therefore remains untrusted data until the protected
verifier chooses a bounded operation; `npm pack` runs only on the disposable hosted VM.

The protected verifier fixes the public package name, binary map, published file
allowlist, registry, build entrypoint, and Node floor. It semantically parses the release
workflow and shipped workflow templates with duplicate-key rejection. Release remains
dispatch-only; action references require 40-hex commits, containers require sha256
digests, and verification steps cannot opt into `continue-on-error`, unconditional
skips, or `|| true`. It then creates an ignore-scripts package archive and rejects
missing public entrypoints or included repository/credential configuration. Both npm 11
array receipts and npm 12 keyed receipts are accepted only when they describe exactly
one `@verjson/cli-projects` package.

The rollout tool is read-only by default and verifies its own reviewed files are byte
identical at a SHA reachable from protected `main`. Apply requires the exact human
acknowledgement and a fresh, unique provider inventory. It creates the organization rule
disabled, reads and compares the complete postimage, activates it, and compares again.
An unreadable, mismatched, or client-failed activation always reads the live postimage,
then attempts and verifies rollback to disabled when the state is not already the exact
disabled image. A retry adopts only one exact disabled staged rule by numeric identity
and complete postimage; it resumes activation instead of creating a duplicate. One exact
active rule is an idempotent success, while ambiguity or any other image fails closed.

Repository ruleset `21567958` is a separate second transaction. It remains in
`evaluate` until a fresh exact-head run proves the organization-required workflow URL,
path, SHA, event, conclusion, and activation-time ordering. Only then may
`activate-repository` issue a PUT from an immediate exact preimage whose sole changed
field is `enforcement`, followed by a complete GET comparison. Drift or partial API
failure first reconciles live state and restores/verifies the exact `evaluate` preimage;
the old rule stays non-blocking until evidence binding is live.

The general organization ruleset audit keeps its release-App bypass invariant. Its
policy contains one narrow bypassless exception for this exact ruleset name, consumer
ID, workflow repository/path/ref, active enforcement, immutable SHA, and empty bypass
set. Any widened variant remains a conformance failure.

### 2026-08-30 — Credentialed acquisition also belongs to the required workflow

Issue [#1187](https://github.com/Verjson/.github/issues/1187) found that the
repository-local Node CI caller still granted `packages: read` and mapped its
`GITHUB_TOKEN` from pull-request-controlled YAML. Protecting only the final
package-surface verifier did not protect the earlier credential-bearing call.

Generate this required workflow from a strict repository configuration and move both
secretless Node lanes behind it. A no-checkout admission job validates the exact
pull-request event, repository, numeric pull-request identity, same-repository head,
head SHA, synthetic merge SHA, and merge ref against GitHub's live numeric record. Only
after admission may the workflow call the immutable canonical `node-ci` revision. Its
acquisition job receives package-read authority but never executes candidate code; its
build job restores only the bounded package cache and runs candidate scripts after
credential removal. The second lane proves the Node floor. The original protected
package verifier remains credentialless and now also requires both Node lanes.

The organization required-workflow rule, rather than a repository-owned caller name,
is the pull-request entry-point provenance boundary. The generated repository caller is
push-only, and admission hashes the candidate caller against that exact image before
package acquisition. The rollout tool also requires protected `main` to contain those
byte-exact push-only caller bytes before rotating the organization rule or activating
the repository rule. The transaction binds that read to the exact protected-main commit
and re-projects the branch immediately before and after each write. A moved branch or
ambiguous write response restores and verifies the prior organization workflow or the
repository rule's `evaluate` image. Updating either surface requires a fresh exact-head
canary.

## Consequences

- Pull-request-authored workflows, verifier files, and spoofed check names cannot satisfy
  the organization required-workflow rule.
- The repository-owned caller grants package authority only for pushes to protected
  `main`; it has no pull-request trigger. Candidate caller mutation fails required-
  workflow admission before credentialed acquisition.
- Untrusted package and scaffold behavior has no persistent host, inherited secret, or
  retained checkout credential.
- The package policy affects only `Verjson/verjson-cli-projects`.
- Rollout remains held until this change is merged, independently reviewed, and a fresh
  required-workflow canary succeeds; no live ruleset mutation is part of this change.
- Rollback preserves the repository rule in `evaluate` and restores a newly created
  organization rule to disabled rather than accepting ambiguous enforcement.

### 2026-08-30 — Bind empty-context delivery to authenticated run identity

Issue [#1195](https://github.com/Verjson/.github/issues/1195) established that an
organization-required workflow delivery can omit pull-request event fields. Admission
therefore reads only the current `github.run_id` through the authenticated Actions API,
requires exactly one pull-request binding, and matches its head SHA to one live, open,
same-repository numeric pull request. The admitted event, repository, and immutable head
SHA are outputs consumed by both protected Node lanes and candidate checkout.

Both Node lanes call `node-ci-protected.yml` at immutable organization contract commit
`29e28aa5d4606678dbee93d46dd0663fa55c749b`. Their callers explicitly grant
`actions: read` and `pull-requests: read`; the ordinary push-only consumer remains on the
legacy `node-ci.yml` contract. Missing, ambiguous, stale, closed, malformed, or partially
unavailable identity evidence fails closed before candidate bytes or package authority
are consumed.

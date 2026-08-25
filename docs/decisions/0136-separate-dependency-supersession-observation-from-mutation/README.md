# 0136 — Separate dependency-update supersession observation from mutation

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1084](https://github.com/Verjson/.github/issues/1084)
- **Extends:** [ADR 0109](../0109-observe-first-renovate-compatibility-control-plane/README.md)
- **Extends:** [ADR 0135](../0135-observe-live-generated-caller-capability-floors/README.md)

## Context

Dependency automation can open several pull requests for the same dependency while an
older update is still awaiting review. A newer update may completely contain an older
one, leaving duplicate CI load, conflicts, and uncertainty about which pull request is
authoritative. Canonical CI can compare those updates, document the relationship, and
close the obsolete pull request.

Supersession classification consumes attacker-influenced pull-request titles, bodies,
labels, authors, diffs, manifests, lockfiles, and version strings. A false positive in a
read-only observer produces a report that can be adjudicated. The same false positive
behind a write credential can close legitimate work across every repository where the
credential is installed.

The existing Renovate Compatibility App is deliberately an observation principal. Its
read-only contract, incident response, tests, and installation review assume that
parsing or classification cannot mutate GitHub state. Adding pull-request write access
would silently invalidate that boundary, expose a broadly installed write credential
to the longest and most input-heavy part of the workflow, couple observation availability
to mutation rollback, and invite later permission creep.

## Decision

Implement dependency-update supersession as two independently authenticated phases.

The canonical detector is read-only. It may inspect pull requests and immutable
repository content, classify candidates, and publish a machine-readable proposal and
human-readable summary. It cannot comment, label, close, reopen, push, dispatch, merge,
or otherwise mutate GitHub state. The initial organization rollout remains observe-only
until reviewed receipts establish an acceptable false-positive rate.

A separate trusted terminal reconciler consumes a proposal only from the reviewed
canonical workflow and independently re-fetches all live facts. It treats the proposal
as an untrusted hint, not authorization. Immediately before mutation it must bind the
target organization, repository, default/base branch, candidate and replacement pull
request numbers, base and head commit identities, author App identities, dependency
coordinates, file sets, and version transitions to current GitHub state.

Automatic closure is authorized only when all of these invariants hold:

- both pull requests are open dependency updates authored by an explicitly allowlisted
  bot or GitHub App identity;
- both target the same immutable repository and base branch;
- the replacement contains every dependency coordinate and ecosystem represented by
  the candidate at an equal or newer permitted version;
- grouped updates are compared as complete sets, so partial overlap is report-only;
- neither update is a downgrade, rollback, security exception, manually modified
  change, or mixed-purpose pull request;
- the candidate and replacement heads and their relevant file/blob identities still
  match the reviewed proposal;
- API responses are complete, unambiguous, and internally consistent.

Malformed metadata, unknown ecosystems, non-total version orderings, ambiguous or
duplicate coordinates, truncated diffs, stale heads, changed authorship, incomplete API
responses, token-mint failures, installation mismatches, and concurrent state changes
fail closed without a comment or closure. A rerun is idempotent: the same receipt does
not create duplicate comments, and an already closed candidate is a successful no-op
only when its live state proves this reconciler already performed the closure.

Before closing, the reconciler leaves one durable comment naming the replacement pull
request and the immutable comparison receipt. Comment and closure form one terminal
operation: if the comment cannot be created, the pull request is not closed.

## Terminal GitHub App contract

Provision a purpose-specific GitHub App with this exact contract:

- **Name and canonical slug:** `canonical-dependency-supersession`
- **Repository selection:** all repositories in each adopting organization
- **Repository permissions:**
  - Contents: read
  - Pull requests: write
  - Metadata: read
- **Events and webhook subscriptions:** none
- **Organization permissions:** none

Do not grant Actions, Checks, Commit statuses, Issues, Administration, Secrets,
Packages, Deployments, Environments, Workflows, Members, or any other repository or
organization permission. Pull-request write is sufficient for the terminal pull-request
comment and close operations; a separate Issues permission is not authorized.

Each adopting organization supplies:

- variable `DEPENDENCY_SUPERSESSION_APP_CLIENT_ID`;
- secret `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY`.

The private key is delivered only to the pinned token-mint action. The minted
installation token requests only `contents:read` and `pull-requests:write`, is scoped
to the one independently validated target repository, and is bound only to the terminal
revalidation/comment/close step. It is unavailable to checkout, detection, parsing,
comparison, caches, artifacts, summaries, third-party actions, and diagnostics.

The App name is organization-neutral so adopters do not encode the source organization
in their credential contract. If GitHub reports that the globally unique name is
unavailable, provisioning stops and this ADR is extended with one reviewed neutral
replacement; implementations must not silently invent organization-specific suffixes.

## Trust boundaries

- Pull-request and repository content is untrusted even when attributed to a bot.
  Detection parses it without a write credential.
- The detector proposal is evidence, not authority. The reconciler independently
  retrieves and validates current state using the exact repository-scoped App token.
- Repository owner/name, pull-request numbers, refs, authors, dependency coordinates,
  and file paths never flow directly from event or artifact data into token scope or a
  mutating API call.
- The App installation may cover all adopter repositories, but each token covers
  exactly one validated repository and exists only for the terminal operation.
- The closer never executes candidate or replacement code and never uses
  `pull_request_target` to run pull-request-controlled content.
- Human-authored and manually modified pull requests are outside automatic authority,
  regardless of labels, titles, or dependency-shaped diffs.
- A successful replacement is not inferred from a mutable title, branch, label, or
  Renovate body. Immutable commits, blobs, parsed dependency sets, and live App
  authorship are required.

## Rollout

Land the detector and adversarial contract tests first. Retain organization-wide
observe-only artifacts before enabling the reconciler. Then use disposable bot-authored
pull requests to canary one exact-repository token, one documented supersession comment,
and one closure. Independent security review must cover authentication, repository
scope, token delivery, parser boundaries, grouped-update completeness, live-state
revalidation, idempotency, and rollback before write mode is enabled.

## Consequences

The split introduces a second App and a second workflow phase, but compromise or a bug in
the detector alone cannot close work. The write credential has smaller scope, shorter
exposure, and a simpler auditable call graph. Mutation can be disabled or the App
revoked without losing compatibility visibility.

Some apparent duplicates will remain open when version ordering or update coverage is
ambiguous. That is intentional: the safe failure mode is an inaccurate observation or
an unclosed duplicate, never an incorrectly closed legitimate pull request.

## Rollback

Disable the terminal reconciler or uninstall/revoke the supersession App. The read-only
detector may continue operating. Reopen any pull request named in a retained reconciler
receipt if adjudication proves the closure incorrect; do not delete the comment or
receipt, because they are the forensic record.

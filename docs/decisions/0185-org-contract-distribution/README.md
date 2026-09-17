# 0185 — Distribute the organization contract as a version, not a commit

- **Date:** 2026-09-17
- **Status:** Accepted
- **Related:** [ADR 0038](https://github.com/Verjson/.github/tree/main/docs/decisions/0038-canonical-changelog-contract), [ADR 0178](../0178-publish-deferred-ci-as-its-own-check/README.md), [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md)
- **Issues:** [#1366](https://github.com/Verjson/.github/issues/1366) (fleet detection), [Verjson/verjson-ci#184](https://github.com/Verjson/verjson-ci/issues/184) (the live defect that exposed this)

## Context

This repository distributes CI, changelog, and ADR machinery to roughly 95
adopter repositories. Distribution today has two shapes:

- **Hand-pinned callers** — one `uses:` commit SHA per workflow file
  (`ci.yml`, `actionlint.yml`, the AI merge/review callers, the gate-rearm
  callers).
- **Generated adopter artifacts** — `changelog.yml`, `release.yml`,
  `changelog-contract.yml`, `scripts/render-next.sh`, `scripts/gen-adr-index.sh`, and the adopter-side
  generated contract test, produced as an atomic set by
  `scripts/gen-changelog-caller.sh` and valid only when regenerated together at
  one contract SHA.

Nothing bumps either shape and nothing detects staleness, so every adopter rots
on its own schedule.

An earlier framing treated these as two independent pipelines — "org automation
contracts" versus "the CI product" — each needing its own permanent detection
and remediation mechanism. **That framing is rejected.** Both are the same
problem, distributing a versioned contract to many consumers, and the split is
an implementation accident rather than an architectural boundary.

### Evidence, gathered 2026-09-17

| Fact | Source |
| --- | --- |
| Intra-repo pin skew is real: `verjson-ci` `ci.yml`/`actionlint.yml` @ `70ddabe0`, `changelog.yml`/`release.yml` @ `d229f8f4` | `Verjson/verjson-ci .github/workflows/*` |
| That skew is not cosmetic — the stale pin predated ADR 0178 and let a deferred head report green | `Verjson/verjson-ci#184` |
| Generated files are self-describing: mode + contract SHA in the header | `Verjson/verjson-ci .github/workflows/changelog.yml:3` |
| In-tree package versions are `0.0.0` placeholders stamped at release | `release.yml` "Stamp the dispatched package versions" |
| `@verjson/ci` published: one version, `0.1.0`, registry visibility private | `gh api /orgs/Verjson/packages/npm/ci` |
| `@verjson/compliance` and `@verjson/compliance-schema`: `0.2.0/0.3.0/0.4.0` — exactly the 3-version retention floor | `gh api /orgs/Verjson/packages/npm/<pkg>/versions` |
| `NODE_AUTH_TOKEN` is an **org-level Actions secret with visibility `all`** | `gh api /orgs/Verjson/actions/secrets` |
| Adopters already forward it to the reusable workflow | `Verjson/verjson-ci .github/workflows/ci.yml:20` |
| The PR lane runs secretless with an explicit internal-package allowlist | `Verjson/verjson-ci .github/workflows/ci.yml` `approved-internal-packages` |

The org-secret fact matters because a cross-repository private-package
credential rollout was assumed to block package-based distribution. It does
not. That credential path is already built, already org-wide, and already used.

## Root cause

**The contract has a commit identity instead of a release identity.**

A SHA is a content address. It cannot express which contract an adopter is on,
whether that contract is behind, or whether it is still supported. Accepting
SHA-as-identity is what forces:

- answering "am I current?" by **content diffing**, because there is no version
  to compare;
- **bots** to perform propagation that a dependency resolver performs natively;
- **two updater categories**, because copied files and referenced files drift
  differently;
- **partial adoption states**, because nothing constrains a repository to one
  contract at a time.

Every compensating subsystem previously proposed — drift tests, propagation
bots, per-category updaters — exists to work around this one error.

### Why the obvious drift test is also wrong

A pin is a repository commit, not a file's last-touching commit, so comparing a
pin against `repos/Verjson/.github/commits?path=<file>` compares unrelated
things and returns false results in both directions. That invalid test is why
`#184` went unseen.

The usual replacement — blob identity at the pinned ref versus the default
branch — is better, and must still not be enshrined:

1. **It fails open.** `a=$(gh api …); b=$(gh api …); [ "$a" = "$b" ]` reports
   *current* when both calls fail: a rate limit mid-sweep, an expired token, or
   a garbage-collected pin ref all yield `"" = ""`. Any implementation must
   assert both sides are non-empty 40-hex object ids before comparing.
2. **It is the wrong granularity.** A reusable workflow's behavior is its whole
   tree at that ref — composite actions, `scripts/changelog.py`, nested
   workflows. One file can be byte-identical while a transitively referenced
   script has drifted.
3. **It is semantically noisy.** A comment-only upstream edit reports drift.
   Noisy checks get muted, which is how the previous invalid test survived.

Content diffing is a workaround for the absence of versioned contracts. Under
the decision below the test becomes a version comparison and all three problems
disappear.

## Decision

Make contract distribution a **versioned release** problem.

1. **Release the contract; do not reference it.** This repository publishes an
   immutable, semver'd contract release — workflows, `changelog.py`, the
   contract test, and the local tooling — with a changelog, a compatibility
   policy, and a supported-version window.
2. **One version per adopter, declared in one place.** An adopter records a
   single contract version, not five SHAs across six files. A schema in which a
   repository can be partially on two contracts is wrong; `verjson-ci`'s own
   two-SHA skew is the existence proof, and `#184` is what it cost.
3. **Adopter files are declaration, never implementation.** Generated artifacts
   stop existing; implementation is invoked, not copied. This deletes the
   generated-set atomicity hazard, the Renovate-exclusion requirement, and the
   generator-aware remediation bot together.
4. **Propagation is push-based and staged.** Publishing version N rolls out
   canary → cohort → fleet, halting automatically on failure. Detection survives
   only as an *assertion* — a required check failing a pull request that
   declares an unsupported version — never as the discovery mechanism.
5. **Staleness fails loudly, on a clock.** Support the current and previous
   minor; refuse older with a dated deprecation error. This makes deliberate the
   one good property that registry retention supplies incidentally, and it is
   what lets the hub evolve at all.
6. **The adopter inventory lives in the hub.** Reconstructing invocations by
   parsing generated headers reads state out of the artifacts that state
   produced, and makes adopter-controlled text an input to hub-privileged
   automation across ~95 repositories — any writer to any of them could craft
   flags. Headers remain human traceability only; the hub holds the source of
   truth, and a declaration-versus-reality mismatch is itself an alarm.
7. **Conformance-test the contract at the hub, against synthetic adopters,
   before release.** `#184` is a contract defect that a hub-side conformance
   matrix should have caught before publication, not a drift finding.
8. **Make "green without work" structurally impossible.** A check that skips its
   work reports a state distinguishable from success (ADR 0178), and merge gates
   assert positive evidence of execution on required checks rather than the
   absence of red (ADR 0184).

### Delivery channels under one version

Two artifact kinds, one release train, one version number:

| Consumer | Channel | Rationale |
| --- | --- | --- |
| CI-executed contract (`changelog.py`, contract test, reusable workflows) | reusable workflow ref | Needs no adopter-resident file beyond the caller, and a `uses:` must be a git ref, so npm cannot serve it. |
| Developer-executed tooling (`render-next.sh`, `gen-adr-index.sh`) | published package `bin` | A workflow cannot give a human a local command. This is exactly why these were copied into adopters; a package is the correct fix. |

This is the precise answer to "shouldn't every repository just depend on the
`@verjson/ci` package": not one package, but **one versioned organization
platform contract**, of which npm is one channel and the workflow ref another.
`verjson-ci` is a peer spoke and a *consumer* of the contract, not an
intermediary; nothing may assume adopters inherit through it.

## Rejected options

- **Keep two permanent pipelines with per-category updaters.** Preserves the
  root cause and institutionalizes two mechanisms to manage drift that
  versioning removes.
- **Detection plus a regenerator bot as the end state.** A compensating control
  for missing delivery, and unresolvable against the ownership boundary:
  detection must cover ~95 repositories while remediation may only open pull
  requests in the ones we own.
- **Moving tags (`@v1`) instead of versions.** Removes drift, but also removes
  the audit trail and the ability to state which contract a repository ran.
  Immutable versioned releases keep both.
- **Distributing the contract as a private npm dependency alone.** Viable now
  that `NODE_AUTH_TOKEN` is org-wide, but it cannot carry the reusable
  workflows, and it adds a manifest, a lockfile, and an
  `approved-internal-packages` entry per adopter for tooling the CI lane could
  invoke directly.

## Consequences

- A release train and a compatibility policy for this repository.
- A conformance harness with synthetic adopters.
- A one-time migration of ~95 repositories from SHA pins and vendored files to a
  version declaration.
- A staged rollout controller.
- **Detection covers ~95 repositories; automated remediation covers 8.** Read-only
  detection needs no write authority and reaches the whole fleet. Remediation may
  open pull requests only in `Verjson/.github`, `verjson-ci`, `verjson-cli`,
  `verjson-cli-cloud`, `verjson-cli-projects`, `verjson-git-runners`,
  `verjson-compliance`, and `verjson-compliance-schema`. Every other adopter
  receives a tracked issue carrying a proposed diff. Fleet-wide pull requests
  must be budgeted against real review capacity before they are opened; a
  migration that opens 87 unreviewable pull requests has not migrated anything.
- Months of work touching CI in every repository in the organization. Recorded as
  a fact, not as a reason to prefer the cheaper design.

Until the migration lands, the existing pins remain authoritative and read-only
detection supplies the inventory.

## Verification

This decision is a direction, and the steps that implement it carry their own
verification. What is verifiable today: `scripts/fleet-contract-inventory.py`
produces the per-file migration inventory this decision depends on, and asserts
non-empty 40-hex object ids on both sides of every comparison so a sweep that
cannot resolve a ref reports `UNKNOWN` rather than `CURRENT`. Its regression
suite is `scripts/ci-gate/fleet-contract-inventory.test.py`.

# 0060 — `node-release.yml` is retired: a release is dispatched, never derived from a merge

- **Date:** 2026-08-06
- **Issues:** [#460](https://github.com/Verjson/.github/issues/460)
- **Extends:** ADR 0038 (canonical changelog contract), ADR 0052 (`push_token` is not `GITHUB_TOKEN`)
- **Category:** release authority — **sensitive class**

## Context

ADR 0038 decided that a release is a `workflow_dispatch` naming the version to cut, and
that a pinned `scripts/changelog.py release` consumes the accumulated `NEXT/` fragments
into one immutable `CHANGELOG/<version>.md` snapshot. Merging `main` publishes nothing.

`node-release.yml` predates that decision and contradicts it: it runs `semantic-release`,
which derives the version from commit subjects at merge time. Every caller of it releases
on merge — the exact model ADR 0038 replaced.

The decision was recorded but never enforced, so adoption stalled halfway. Measured across
the organization on 2026-08-06 (`release.yml` plus a sweep of every other workflow file):

| shape | count | repositories |
| --- | --- | --- |
| migrated — `workflow_dispatch` -> `changelog-release.yml@f12dca7` | 12 | verjson-ai, verjson-authn, verjson-browser-agent, verjson-cli-projects, verjson-customer-lifecycle, verjson-identity-contracts, verjson-identity-lifecycle, verjson-leads, verjson-observability, verjson-oidc-claims-middleware, verjson-payments, verjson-temporal-kit |
| release-on-merge — `push` -> `node-release.yml` | 8 | verjson-cloud-storage, verjson-cli, verjson-email, verjson-eslint-config, verjson-graphql-conventions, verjson-infra, verjson-upload, verjson-video-forge |

Seven of the eight call it from `.github/workflows/release.yml` on `push: branches: [main]`.
`verjson-cli` is the exception: its release is a job inside `ci.yml`, pinned at
`node-release.yml@8a2522d` rather than `@main`.

A ninth site matters more than any single repository:
`verjson-cli-projects/templates/package/.github/workflows/release.yml.tmpl` **emits** the
push-triggered shape, so every package scaffolded from it is born non-conforming. Migrating
the eight without fixing the template only resets the count.

## Decision

**`node-release.yml` refuses to run.** Its first step, before any checkout and with no `if:`,
prints an error naming the replacement and exits 1.

Two consequences of that shape are deliberate:

**Refusal, not deletion.** Deleting the file makes a straggling caller fail with GitHub's
"workflow not found", which names neither the cause nor the replacement. The file stays
resolvable — `workflow_call` intact — purely so the error can say where to go. The body
below the refusal is unreachable; it is history, not configuration.

**Unconditional, not event-filtered.** The first draft gated on `github.event_name == 'push'`,
which is wrong for the reason ADR 0038 gives: the defect is not the trigger, it is deriving
a version from commit subjects. `semantic-release` under `workflow_dispatch` derives it just
the same. There is no event under which this workflow is now correct, so there is no
condition to write.

### Sequencing

The refusal lands **after** the caller migrations, not before. Landing it first turns every
merge to `main` red in eight repositories that have nowhere to go yet — an outage presented
as a policy. Caller migration is delegated per repository (each repository's own PM owns its
publish job, which is not uniform), and this change is held until those land.

### Blast radius

- **`@v1` consumers are unaffected.** That tag is frozen at `e3cf463` (2026-07-24); a change
  on `main` does not reach it. Advancing `v1` is a separate decision (ADR 0022).
- **SHA-pinned callers are unaffected until they move.** `verjson-cli` pins `8a2522d`, so its
  release-on-merge stops when its PM removes the job, not when this lands.
- **`@main` callers stop releasing immediately.** That is the intent, and it is why the
  sequencing above is part of the decision rather than a rollout note.

## Consequences

- The retired machinery below the refusal — locked release tooling, the npm cache inputs,
  the publication outputs of #244 — is now dead code with live tests and a lockfile Renovate
  keeps bumping. Deleting it is a follow-up, not part of this change: the deletion invalidates
  `node-release-version.test.sh`, `node-release-outputs.test.sh` and `release-tooling-audit*`
  together, and mixing that into a release-authority change would bury it.
- `docs/node-workflows.md` still documents the release half as if it were live. It is
  corrected alongside the deletion above rather than left half-edited here.
- A repository that wants release-on-merge back cannot get it by copying a workflow from this
  organization. It has to argue with ADR 0038, which is the point.

## Verification

`scripts/node-release-retired.test.sh` executes the refusal's real `run:` block, extracted
from the workflow, under `set -euo pipefail`. It pins four properties and the callability
that makes the error reachable: the refusal is the job's first step, carries no `if:`, exits
non-zero, and names `changelog-release.yml`. Five mutants die — dropping `exit 1`, adding an
`if:`, moving the step after the checkout, rewording the message off its replacement, and
removing `workflow_call`. The extraction is bounded by line count as well as indentation,
because an extraction guarded only by "non-empty" passes on whatever follows a reshaped step.

## Rollback

Revert the implementing PR. `node-release.yml` runs again exactly as before; no caller state
changes, because the refusal writes nothing. Migrated callers do not roll back with it — they
no longer reference this workflow at all.

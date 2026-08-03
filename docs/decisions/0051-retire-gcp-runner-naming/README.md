# 0051 — Runner naming stops claiming GCP, and the pool grows to ten

- **Date:** 2026-08-03
- **Issue:** [Verjson/.github#346](https://github.com/Verjson/.github/issues/346)
- **Supersedes:** ADR 0011's rule that "new runners join `GCP`/`gce`"
- **Amends:** ADR 0003 (the group it named `GCP` is renamed, not replaced)

## Context

The persistent pool has run on **DigitalOcean** since the #204 migration. The
names did not follow. Every runner still advertised `gce` and `GCP`, and the
runner group was still called `GCP`, on droplets in the `verjson-ci` project of
the `verJSON Common` DigitalOcean team.

Nothing routed on either label. Routing goes through `VERJSON_RUNNER_DEFAULT` /
`VERJSON_RUNNER_UNTRUSTED` / `VERJSON_RUNNER_FASTLANE`, which resolve to
`general`. `.github/actionlint.yaml` already described `GCP` as a "legacy
provider-specific selector, retired by the #203 sweep" while continuing to
declare it. The one place the stale name was load-bearing was
`docs/node-workflows.md`, which documented the Trusted route as
`["self-hosted","GCP"]` — a route no workflow uses.

Separately, the pool was six runners against a workload where `gate` and
`privileged_merge` sleep 10–40 minutes while polling. On 2026-08-03 that
deadlocked completely: 6/6 runners busy, ~15 runs queued organization-wide, and
`verjson-payments`' `build-test` queued 45 minutes without ever being assigned.

## Decision

**Names describe the machine.** `gce` and `GCP` are removed from every runner
registration, from the declared label set, and from the documented routes. The
runner group is renamed `GCP` → `general`, matching the label the routing
variables already resolve to.

**Capacity goes from six to ten.** Four droplets — `gha-general-7` through
`gha-general-10` — join the pool with the same specification as the existing
six: `s-2vcpu-4gb`, `ubuntu-24-04-x64`, `nyc3`, VPC
`e9c142fa-3257-4f41-8dd2-2e9558a70a6b`, tag `verjson-gha-general`. They register
with labels `gate,general` and nothing else.

Ten is the ceiling, not a target: the DigitalOcean team's droplet limit is 10
and six other droplets already exist in the account, so this consumes the
remaining headroom. Going further needs a limit increase from DigitalOcean.

### The group rename is the risky part

`scripts/ci-gate/runner-admission-reconcile.sh` resolves the pool **by name**,
not by id — deliberately, because ADR 0033 records that group ids are not stable
over an org's lifetime (group 6, `isolated`, was deleted in #266). So
`GENERAL_GROUP_NAME` defaulted to `GCP`, and renaming the group without changing
that default makes the reconciler fail closed on every run with "no runner group
is configured for lane".

The default moves to `general` in the same change that renames the group. The
reconciler runs on a schedule rather than per-PR, so the ordering window is
small, but it is real: **the code lands first, then the group is renamed.**

## Consequences

- A label finally means what it says. ADR 0011's fourth principle — "labels
  describe capability, not just provider" — is honoured rather than stated.
- Any workflow anywhere selecting `[self-hosted, GCP]` stops resolving. A sweep
  of this repository found exactly one such selector, and it was
  `actionlint.yml`'s own positive-control fixture, which needs *a* declared
  label rather than that one. Consumer repositories were not swept; a consumer
  pinning `GCP` directly would break, which is the point of removing a name that
  no longer describes anything.
- Ten runners do not fix the deadlock, they widen it. `gate` and
  `privileged_merge` still hold a runner while polling, so the pool is still
  consumed by sleepers — there are just four more before it saturates. #341 is
  the fix; this buys time for it.
- ADRs 0003 and 0011 keep their `GCP` references. They record what was true when
  written and are superseded, not edited.

## Alternatives rejected

**Leave the names alone.** They were merely cosmetic right up until they were
not: `docs/node-workflows.md` had already taught a wrong route, and the group
name had become the reconciler's lookup key. A name that lies eventually gets
depended upon.

**Rename the group by id instead of by name.** ADR 0033 rejected id-keying
already, for a reason that still holds — ids are not stable across deletions.

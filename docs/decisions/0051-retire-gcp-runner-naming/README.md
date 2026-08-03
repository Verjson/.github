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

**Names describe the machine.** The documented routes and the declared label
set stop naming `GCP`, and the runner group is renamed `GCP` → `general`,
matching the label the routing variables already resolve to.

**The labels themselves stay on the runners for now.** They were removed on
2026-08-03 and restored within the hour, because removing them wedged
`Verjson/verjson-observability` instantly: its workflows pin
`[self-hosted, GCP]` directly, and a `runs-on` matching no runner does not fail
— it queues forever, with no check run and no error, while the fleet sits idle.
That is the #130/#191 failure shape.

At least nine repositories pin the label directly. The correct order is: sweep
and migrate every consumer, verify nothing queues against `GCP`/`gce`, remove
the labels from the runners, and only then drop them from the declared set — a
consumer still pinning `GCP` must fail actionlint *after* it stops scheduling,
not before. #365 owns that migration.

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
- Sweeping only this repository was the mistake that caused the outage. It found
  one selector — `actionlint.yml`'s positive-control fixture — and that was
  taken as licence to remove the labels. Consumers were the population that
  mattered, and at least nine of them pin `GCP` directly. "A consumer pinning
  `GCP` would break" was written in the original PR as an accepted consequence;
  it was in fact an outage, because the break is silent and unbounded rather
  than a failed job.
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

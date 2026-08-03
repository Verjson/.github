---
date: 2026-08-03
id: 20260803T145500Z
refs: 346
title: Runner naming stops claiming GCP, and the pool grows from six to ten
---

The persistent pool has run on DigitalOcean since the #204 migration; the names
never followed. Every runner still advertised `gce` and `GCP`, and the runner
group was still called `GCP`, on droplets in the `verjson-ci` project of the
`verJSON Common` DigitalOcean team.

Both labels were stripped from all six live runners on 2026-08-03. Nothing
routed on them — routing resolves through `VERJSON_RUNNER_*` to `general` — and
`.github/actionlint.yaml` had already called `GCP` a "legacy provider-specific
selector, retired by the #203 sweep" while continuing to declare it.

One place the stale name was load-bearing: `docs/node-workflows.md` documented
the Trusted route as `["self-hosted","GCP"]`, a route no workflow uses.

The riskier half is the group rename. `runner-admission-reconcile.sh` resolves
the pool **by name** — deliberately, since ADR 0033 records that group ids are
not stable — so `GENERAL_GROUP_NAME` defaulted to `GCP`. Renaming the group
without moving that default makes the reconciler fail closed on every run. The
default moves in this change; the group is renamed after it lands.

Capacity also goes six → ten. `gha-general-7` through `gha-general-10` match the
existing spec (`s-2vcpu-4gb`, `ubuntu-24-04-x64`, `nyc3`) and register with
`gate,general` and nothing else. Ten is the ceiling, not a target: the team's
droplet limit is 10 and six unrelated droplets already exist in the account.

This does not fix anything, it widens the runway. `gate` and `privileged_merge`
still hold a runner while polling, so four more runners is four more sleepers
before saturation — the same deadlock that stalled `verjson-payments`'
`build-test` for 45 minutes on 2026-08-03, just later. #341 is the fix.

See [ADR 0051](docs/decisions/0051-retire-gcp-runner-naming/README.md). ADRs
0003 and 0011 keep their `GCP` references: superseded, not edited.

---
date: 2026-08-03
issue: 332
title: Short CI jobs get a fast lane, selected by variable rather than a hardcoded label
---

All six self-hosted runners carry the same labels, so the three
`VERJSON_RUNNER_*` pools name one queue three times. That queue mixes jobs with
opposite shapes: `gate` and `privileged_merge` hold a runner for 10-40 minutes
while *polling*, while `shell-tests` is minutes of actual CPU. On one queue the
sleepers evict the workers, and this repository's own validation ended up queuing
behind the consumer repositories it ships fixes to.

`shell-tests` now runs in a fast lane chosen by `VERJSON_RUNNER_FASTLANE`,
currently `["ubuntu-24.04"]`. This repository is public, so those minutes are
free — billing measured 2026-08-01 shows public repositories running hosted at
$0, which corrects ADR 0033's premise that hosted is unfunded org-wide.

It is routed through a **variable**, not `runs-on: ubuntu-24.04`, so a dedicated
self-hosted fast pool later is an org-settings edit rather than a workflow edit,
and an unset variable degrades to ADR 0034's general pool instead of failing.
`runner-routing-policy.test.sh` asserts all three properties, including that the
old hardcoded form is now a failure, so the ADR 0034 exception cannot quietly
return.

Deliberately unchanged: `gate` and `privileged_merge` still hold a runner while
waiting. They are the actual occupancy problem, and hosted runners would not fix
it — a poll loop wastes a hosted minute exactly as it wastes a self-hosted one.
See [ADR 0047](docs/decisions/0047-fast-lane-runner-variable/README.md).

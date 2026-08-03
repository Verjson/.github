---
date: 2026-08-03
issue: 363
title: A runner without gh fails the gate in a second instead of holding it for thirty minutes
---

`ci_wait` treated every non-zero return from `gh` as "the API is unavailable"
and retried. Exit **127** is not a transient API error — it is
`command not found`. On a runner without `gh` every call failed instantly and
identically, the loop spent all 60 attempts on it, and the job failed closed
after thirty minutes:

```
phase=ci-wait result=checks-unavailable elapsed_seconds=1772 attempt=60/60
  checks_endpoint_rc=127  statuses_endpoint_rc=127  gh_version=unavailable
```

This is a fleet outage rather than a slow job, because `gate` polls **on the
same pool as the CI it waits for**. A mis-provisioned runner does not just fail
its own jobs — it removes a slot for thirty minutes per job while the CI that
would break the deadlock queues behind it.

Four runners were added to a six-runner pool on 2026-08-03 without `gh`. Instead
of adding 40% capacity they removed it: every gate job that landed on one could
only fail, slowly, holding a slot throughout. The organization stalled with
runners sitting idle.

Both workflows now assert `gh` and `jq` before their first use and fail
immediately, naming the tool and the runner so the operator fixes a machine
rather than re-running a PR. Every swallowed mid-run path additionally treats
127 as terminal, including self-job enumeration, check aggregation, trusted-gate
discovery, and attestation retrieval. `ai-privileged-merge.yml` had the same
shape with a ~40-minute window and gets the same protection.

`toolchain-missing.test.sh` runs the extracted `run:` block with `gh` genuinely
absent from `PATH`. A stub cannot model this: the bug was precisely that a
missing binary was indistinguishable from a failing API, so the absence has to
be real. It pins that the failure takes under ten seconds rather than thirty
minutes, and that the message identifies the runner. The existing extracted
gate and privileged-merge suites force each mid-run lookup to return 127 and
prove those branches terminate rather than entering the retry loops.

This removes the amplifier, not the cycle. The gate still holds a runner while
polling in the healthy case, which is #341.

The provisioning error was avoidable: the four runners were built by hand with a
native systemd install instead of from `Verjson/verjson-github-runner`, whose
published image ships `gh` by construction. They are being moved onto that
image. The gate should fail fast regardless — "someone eventually adds a bad
runner" is a certainty, not a hypothesis.

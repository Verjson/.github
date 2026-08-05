---
date: 2026-08-05
issue: 401
title: Run the admission monitor off the pool it watches, and follow a group rename by variable
---

Every `[self-hosted, general]` job in this repository queued indefinitely while
five `general` runners sat idle. The pool had moved into runner group
`DigitalOcean` with `allows_public_repositories: false`, and this repository is
public, so no runner in that group was an eligible target. GitHub queues such a
job instead of failing it — no check-run diagnostic, no error. The merge gate
wedged behind it: #400 sat with `gate` and `dispatch-merge` green and
`privileged_merge` unable to start.

`runner-admission-reconcile` exists to catch exactly this, and models it
correctly — its suite already had a passing *public repository denied by group is
reported as drift* case. It could not report, because it ran on
`[self-hosted, general]` itself. The 10:16 run never started; the last completed
run was the previous morning's. A monitor that depends on the resource it
monitors goes quiet in the one outage it was built for, so it now runs on the
fast lane.

It was blind for a second reason. The `GCP` → `DigitalOcean` move renamed the
group. Lane labels survive a rename because they come from `VERJSON_RUNNER_*` —
`node-ci.yml` says so itself, "a variable flip, not a PR here" — but the group
name was still in code, so the reconciler resolved nothing:

```
UNDETERMINED: runner group 'GCP' (selected by the general lane) does not exist in
Verjson; present groups: GitHub, manish, DigitalOcean, verjson-runner-maintenance
```

That is #266 recurring by name rather than by id. `GENERAL_GROUP_NAME` now comes
from `vars.VERJSON_RUNNER_GENERAL_GROUP` with a `DigitalOcean` fallback, and the
fixtures use the shipped default so a stale default fails the suite rather than
resolving nothing in production.

`runner-admission-reconcile.yml` is deliberately removed from the routing
contract that holds repository-local jobs on the general lane, with a dedicated
assertion in its place so the monitor cannot be tidied back inside the thing it
watches.

The admission change itself is org configuration, not code: runner group
`DigitalOcean` is now `visibility: all` with public repositories allowed, per the
standing requirement that any public Verjson repository can use the general pool.
ADR 0054 records it, including the residual risk that `VERJSON_RUNNER_UNTRUSTED`
and `VERJSON_RUNNER_DEFAULT` still resolve to the same pool.

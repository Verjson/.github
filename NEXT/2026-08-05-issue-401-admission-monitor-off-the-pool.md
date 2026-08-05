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
`[self-hosted, general]` itself. Its 10:16 run did not start until 14:22:28,
seconds after the group was opened, and then failed 11s later on the stale group
name below — one run showing both defects in sequence. A monitor that depends on
the resource it monitors goes quiet in the one outage it was built for, so it now
runs on the fast lane.

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
fixtures use the shipped default so the two cannot be edited apart. That is not
drift detection — a rename in the live org still passes the suite, because no
static file can know the fleet; the reconciler's own runtime `UNDETERMINED` is
the only detector, which is why moving it off the pool is the load-bearing half.
`UNTRUSTED_GROUP_NAME` loses its default entirely rather than gaining a fresh
one: it named `isolated`, a group deleted on 2026-07-31, so it now fails closed
saying no group is configured instead of reporting a long-dead one as missing.

`runner-admission-reconcile.yml` is deliberately removed from the routing
contract that holds repository-local jobs on the general lane, with a dedicated
assertion in its place so the monitor cannot be tidied back inside the thing it
watches.

Every `runs-on:` in this repository now names a **lane** rather than a label:

```yaml
runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
```

`PRIVILEGED` for the merge gate's elevated token, `UNTRUSTED` for jobs touching
pull-request content, `TRUSTED` for everything else. Migration step 2 of
`docs/runner-routing.md` had never been taken, so the model existed on paper
while a fleet label sat in every selector — including the reusable workflows
~90 consumers call, where a relabel would have to land everywhere at once.
Replacing the literal with a variable is the whole point; leaving
`'["self-hosted","general"]'` as the fallback would have kept the coupling one
level down. The terminal `'["ubuntu-24.04"]'` is ADR 0040's portability
contract, reached only by an org with no lane variable set at all.

`VERJSON_RUNNER_FASTLANE`/`_OVERFLOW` keep their names deliberately: they select
hosted versus self-hosted, an orthogonal axis, and folding them in would put the
admission monitor and the fleet watchdog back on the pool they police. The
`VERJSON_RUNNER_*` variables stay set, because consumers pinned to an older SHA
still read them.

The same fleet move also took `gce`, `GCP` and `gate` off the runners while
workflows still selected them — steps 5 and 6 of the migration sequence in
`docs/runner-routing.md` ran in the wrong order, which that document warns
produces jobs that queue forever with no check run.
`Verjson/verjson-identity-lifecycle`'s `generated-docs` job is sitting in exactly
that state on `[self-hosted, GCP]`. Those labels are now undeclared in the
organization-wide `.github/actionlint.yaml`, so naming one fails lint with a file
and a line instead of hanging a pull request, and every repository-local
`runs-on` here selects its lane through `vars.VERJSON_RUNNER_*` with a live-label
fallback rather than a literal.

The admission change itself is org configuration, not code: runner group
`DigitalOcean` is now `visibility: all` with public repositories allowed, per the
standing requirement that any public Verjson repository can use the general pool.
ADR 0054 records it, including the residual risk that `VERJSON_RUNNER_UNTRUSTED`
and `VERJSON_RUNNER_DEFAULT` still resolve to the same pool.

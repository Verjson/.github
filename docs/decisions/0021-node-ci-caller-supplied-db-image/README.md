# 0021 — node-ci runs a caller-supplied DB image on the shared self-hosted pool

- **Date:** 2026-07-22
- **Issue:** Verjson/.github#117 (follow-up to #108 / PR #113)
- **Category:** reusable-workflow security posture (runner topology · secrets)

## Context

PR #113 (#108) added optional, default-off DB-service inputs to the reusable
`node-ci.yml`: when a caller sets `db-image`, the workflow runs that image via
`docker run` on the same **shared self-hosted runner** that executes the job, and
exports `db-env` pairs (incl. `DATABASE_URL`) to the test step. The AI merge-gate
review of #113 flagged (#117) that this lets a reusable-workflow caller run an
**arbitrary container image on the shared runner pool**, which touches two items
on the sensitive-class list (`runner topology`, `secrets`) — and asked whether it
warrants a decision record. It was merged as additive/non-breaking without one;
this ADR closes that gap by recording the decision and its envelope rather than
reversing it.

## Decision

Allow a caller-supplied `db-image` to run on the shared self-hosted pool, under
this trust model and with these constraints:

- **Trust boundary = the caller.** `db-image`/`db-env` are `workflow_call` inputs
  set by a first-party Verjson/tequityapp repo's own workflow, not by untrusted PR
  content. A repo that can call `node-ci.yml` already runs its own trusted code on
  the pool; supplying a DB image is within that existing trust, not an escalation
  of it.
- **Default-off, no behavior change.** Callers that don't set `db-image` get no
  container and no new surface (pinned by `node-ci-db-service.test.sh`).
- **Job-scoped, self-cleaning.** The container is named per job and torn down in an
  `if: always() && inputs.db-image != ''` step, so a job can't leak or collide a
  container onto the persistent runner (ADR-adjacent to the fixes in PR #113;
  test-pinned per #115). Originally scoped to `run_id`/`run_attempt`; widened to the
  job in the 2026-07-25 amendment below.
- **`db-env` is not GitHub-masked.** It is documented at the input that values are
  not secrets-masked and must be trusted, non-sensitive test credentials — real
  secrets belong in `secrets`, not `db-env`.

### Rejected / deferred alternatives

- **Allow-list `db-image` to `postgres`/`pgvector` only.** Rejected now: it adds
  maintenance and blocks legitimate DB variants while the caller is already
  trusted. Revisit if `node-ci.yml` is ever exposed to a less-trusted caller set.
- **Run the DB in an ephemeral / rootless sandbox instead of the shared runner.**
  Deferred: no ephemeral pool exists today (see the runner-topology work in #103);
  when one lands, DB-backed jobs are a candidate to move there.

## Consequences

- The security posture of the optional DB path is now recorded: it is safe **only
  while callers are first-party and trusted**. Any future change that widens who
  can call `node-ci.yml` (e.g. public forks) must re-open this decision — an
  arbitrary image + unmasked env on a shared runner is not acceptable for
  untrusted callers.
- The single-host concurrency limit (fixed port 5432, run-scoped name) was tracked
  separately in #116; it is a scaling constraint, not a security one. **Resolved —
  see the 2026-07-25 amendment below.**
- No code change ships with this ADR — it documents an already-merged decision and
  sets the boundary condition (trusted callers only) for future changes.

## Amendment — 2026-07-25: concurrency-safe container name and host port (#116)

**Context.** The Consequences above parked the single-host concurrency limit as a
scaling constraint. It is now a real one: a fixed `-p 5432:5432` bind and a name
scoped only by `run_id`/`run_attempt` mean the *second* DB-backed job to land on a
self-hosted host fails outright — the port is taken and the container name is
already in use. Two DB-backed callers, or two matrix legs of one, cannot share a
host. This amends the "run-scoped, self-cleaning" constraint of the decision
rather than reversing it; the trust model (first-party callers, caller-supplied
image, default-off, unmasked `db-env`) is unchanged.

**Amended constraint.**

- **Name is job-scoped, not run-scoped.** `ci-postgres-<run_id>-<run_attempt>-<hash>`
  where the hash covers `GITHUB_JOB`, `RUNNER_NAME` and `RUNNER_WORKSPACE` as well.
  Two concurrent jobs on one host are by construction served by two distinct runner
  processes (a runner executes one job at a time), so the runner identity separates
  them even when run and job ids match. The name is a pure function of the job's
  environment, and the start step publishes it as a step output so the
  `if: always()` teardown removes exactly the container that was started.
- **Host port is OS-assigned and loopback-only** (`-p 127.0.0.1::5432`), read back
  with `docker port` and substituted into the URL-shaped `db-env` values exported to
  `$GITHUB_ENV` (also exported as `$DB_PORT`). This *tightens* the posture of the
  original decision: the caller-supplied image was previously published on
  `0.0.0.0:5432` and is now reachable only from the runner's own loopback.
- **Input surface is unchanged** — `db-image`/`db-env` keep their names, defaults and
  default-off semantics; only the `db-env` documentation changes, because a `:5432`
  in a caller's URL is now a placeholder that gets rewritten (and a URL with no port
  gets one inserted).

**Evidence.** `scripts/ci-gate/node-ci-db-service.test.sh` extracts the step from
`node-ci.yml` and pins, against a stubbed docker: two concurrent jobs get distinct
container names; no fixed host-port bind; the exported `DATABASE_URL` carries the
port `docker port` actually reported (including an IPv6-shaped `[::]:PORT` mapping);
an unreadable mapping fails the step instead of exporting a dead URL; teardown
removes the exact container the start step created, and is a no-op when none was.

**Not re-opened.** The boundary condition of the original decision still stands: an
arbitrary caller-supplied image plus unmasked `db-env` on a shared runner is safe
only while callers are first-party and trusted.

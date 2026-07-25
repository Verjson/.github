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
- **Job-scoped, self-cleaning.** The container is named per job and torn down by its
  container ID in an `if: always() && inputs.db-image != ''` step, so a job can't
  leak or collide a container onto the persistent runner (ADR-adjacent to the fixes
  in PR #113; test-pinned per #115). Originally scoped to `run_id`/`run_attempt`;
  widened to the job, and moved onto the container ID, in the 2026-07-25 amendment
  below.
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

- **The handle is the container ID, and the name is only for humans.** The name is
  still job-scoped — `ci-postgres-<run_id>-<run_attempt>-<hash>`, the hash covering
  `GITHUB_JOB`, `RUNNER_NAME` and `RUNNER_WORKSPACE` — because two concurrent jobs
  on one host are normally served by two distinct runner processes (a runner
  executes one job at a time). Nothing load-bearing rides on that premise: the start
  step captures the ID `docker run` prints, publishes **that** as its step output,
  and drives `docker port`/`exec`/`logs` and the `if: always()` teardown off it. An
  ID is unique by construction, so if the name premise ever failed, the losing job's
  `docker run --name` is refused, that job fails loudly, and — having no ID — it
  cannot tear down the winning job's live container. A name-based handle would have
  removed it and killed a healthy job.
- **Host port is OS-assigned and loopback-only** (`-p 127.0.0.1::5432`), read back
  with `docker port` and exported as `$DB_PORT` (written last, so a caller's own
  `DB_PORT` line cannot win the last-wins `$GITHUB_ENV` merge). This *tightens* the
  posture of the original decision: the caller-supplied image was previously
  published on `0.0.0.0:5432` and is now reachable only from the runner's own
  loopback.
- **The caller marks the port; the workflow does not infer it.** `db-env` values
  carry the literal placeholder `${DB_PORT}` (or `$DB_PORT`) where the port belongs
  and the step substitutes the real one. Two rounds of review found bugs in the
  alternative — a `sed` that inferred the port position from the value's shape —
  and each fix moved the bug rather than removing it: it spliced the database port
  into unrelated URLs on any scheme (`API_URL=https://internal.svc/v1` →
  `https://internal.svc:49187/v1`), corrupted `postgres://localhost?sslmode=require`,
  and hard-failed the job for any value containing `port=<digits>` (`--port=3000`,
  `--inspect-port=9229`). Literal token substitution has no shape to misread, so
  that entire class is gone: values without the token are exported byte-identical,
  and the token works in shapes no URL parser handles (IPv6-literal host,
  `jdbc:postgresql:`, libpq `host=… port=… ` keyword strings, quoted values, `@` in
  the password) — all of which the parsing design had to *reject*.
- **A hardcoded 5432 is rejected, never rewritten.** Under the old fixed bind a
  literal 5432 was harmless — it *was* the job's own database. With an OS-assigned
  port it aims the caller's suite at whatever else listens on the host's 5432, which
  on a persistent self-hosted runner can be a real database that migrations would
  truncate. So a 5432 in port position (`:5432` at end or before a non-alphanumeric,
  `port=5432`, a bare `5432` as a `*_PORT` value) fails the step naming the key and
  pointing at `${DB_PORT}`; `:54321`, `:5432a`, `--port=3000` and `--report=1` are
  none of those and pass through. The one shape that still resolves to a database
  port on its own — a `postgres://` URL with no port, which libpq defaults to 5432 —
  is exported untouched but logs a note, so pass-through is never silent.
- **Leaks are labelled and swept, with the age bound computed in-shell.** The
  container carries `--label verjson-ci=1` and each start reaps labelled containers
  older than 6h. Docker offers no usable bound for this: `until` is a *prune-only*
  filter and `docker ps --filter until=…` is a hard `invalid filter` error (a first
  attempt used exactly that, so the sweep was a permanent silent no-op), while
  `docker container prune` reaps only *stopped* containers and a leaked one is
  typically still running. So the step lists `{{.ID}} {{.CreatedAt}}` and compares
  ages itself. 6h is the bound because a job cannot outlive GitHub's default
  `timeout-minutes: 360` and its container is created after the job starts — so
  nothing older than 6h can belong to a running job, and a concurrent job's live
  container is never a candidate. A listing or removal that fails warns rather than
  being swallowed, as does a teardown whose `docker rm -f` genuinely fails (which
  fails the step).
- **`db-env` is a BREAKING contract change; `db-image` is unchanged.** A caller who
  wrote `:5432` in a `db-env` URL and relied on it being rewritten must now write
  `${DB_PORT}`; the old spelling fails the step with that instruction rather than
  silently pointing at the host's 5432. This is deliberate and cheap: a survey of
  both orgs (`gh search code 'db-env'`, `'db-image'`, owners `Verjson` and
  `tequityapp`) found **no consumer repo passing either input** — every hit is
  inside `Verjson/.github` itself — and the DB service shipped only days earlier
  (#113, 2026-07-22) with its own input description documenting the concurrency
  limitation as known. Input *names*, defaults and default-off semantics are
  untouched, so callers that set neither input are unaffected.

**Evidence.** `scripts/ci-gate/node-ci-db-service.test.sh` extracts the step from
`node-ci.yml` and pins, against a stubbed docker: two concurrent jobs get distinct
container names, including when only one of `RUNNER_NAME`/`RUNNER_WORKSPACE` differs;
no fixed host-port bind; `${DB_PORT}` and `$DB_PORT` both become the port `docker
port` actually reported, in IPv6/`jdbc:`/libpq/quoted/`@`-in-password values alike; a
hardcoded 5432 is rejected by name in six shapes; twelve values carrying neither the
token nor a 5432 — including `https://internal.svc/v1`, `redis://cache/0`,
`s3://bucket/key`, `postgres://localhost?sslmode=require`, `--port=3000` and
`--inspect-port=9229` — are exported byte-identical; a caller's `DB_PORT` cannot
override the real one; a name collision fails the losing job and leaves it no handle,
so it cannot remove the winner's container; an unreadable mapping fails the step
(dumping the container's logs) instead of exporting a dead URL; a container created
8h/3d ago is swept while one created 2 minutes ago is left alone, a listing failure
and an unreadable creation time each warn without failing the step; and teardown
removes the container by ID, fails loudly on a refused removal, tolerates an
already-gone container, and is a no-op when none was started. The suite is
mutation-checked: 13 deliberate defects — dropping either placeholder substitution,
each of the three 5432 rejections, re-introducing the scheme-based `sed`, restoring
the `until=6h` filter, inverting the sweep cutoff, swallowing either sweep warning,
dropping the `DB_PORT` guard or the pass-through note, and handling the container by
name instead of ID — are each caught by at least one assertion.

**Not re-opened.** The boundary condition of the original decision still stands: an
arbitrary caller-supplied image plus unmasked `db-env` on a shared runner is safe
only while callers are first-party and trusted.

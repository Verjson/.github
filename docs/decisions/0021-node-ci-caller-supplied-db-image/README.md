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
- **Run-scoped, self-cleaning.** The container is named per `run_id`/`run_attempt`
  and torn down in an `if: always() && inputs.db-image != ''` step, so a job can't
  leak or collide a container onto the persistent runner (ADR-adjacent to the
  fixes in PR #113; test-pinned per #115).
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
- The single-host concurrency limit (fixed port 5432, run-scoped name) is tracked
  separately in #116; it is a scaling constraint, not a security one.
- No code change ships with this ADR — it documents an already-merged decision and
  sets the boundary condition (trusted callers only) for future changes.

# 0116 — node-ci accepts a caller-supplied health check and container port

- **Date:** 2026-08-22
- **Issue:** [#986](https://github.com/Verjson/.github/issues/986)
- **Category:** reusable-workflow contract surface (runner topology · trust boundary) — extends ADR 0021

## Context

`node-ci.yml`'s `db-image`/`cache-image` service slots (ADR 0021, amended for
#842) are hardwired to one engine each: `db-image` is verified with
`docker exec <container> pg_isready`, `cache-image` with
`docker exec <container> redis-cli ping` requiring a literal `PONG` reply. Both
publish a fixed container-internal port (`5432`, `6379`).

`Verjson/verjson-ai` needs live-engine CI coverage for Neo4j (Bolt, port 7687)
alongside its existing Apache AGE coverage (which fits `db-image` because AGE
*is* Postgres). Neither engine slot can express that: Neo4j is neither
Postgres- nor Redis-compatible, and its port isn't 5432. Per that repository's
ADR-0029 and its #372/#392 findings, Neo4j sits outside the in-database
tenancy boundary AGE inherits, so this is coverage for a real,
independently-documented risk, not a completeness itch. Filing a bespoke
Neo4j job in the consumer's own `ci.yml` was rejected as the consumer drift
`db-image` exists to remove (ADR 0021): it would duplicate node setup, sit
outside the merge-blocking ruleset, and re-solve the sibling-docker publish
problem `node-ci.yml` already handles — worse, and twice.

Three shapes were weighed (full ranking recorded on the issue, contributed by
the `verjson-ai` PM as an implementation brief):

1. **A caller-supplied health command** (`db-health-cmd`/`cache-health-cmd`),
   defaulted to today's exact checks, plus a caller-supplied container port
   (`db-port`) for `db-image`.
2. **A generic `services:` list** of `{image, port, env, health-cmd,
   port-var}` entries. Removes the "how many slots" ceiling entirely, but is
   materially more work and a much larger blast radius on a contract every
   `node` caller depends on.
3. **A third hardwired slot.** Cheapest, but only relocates the problem to
   the next engine that isn't Postgres, Redis, or whatever the third slot
   assumes.

## Decision

Adopt option 1. `db-image` gained `db-port` (container-internal port,
default `5432`) and `db-health-cmd` (default `pg_isready`); `cache-image`
gained `cache-health-cmd` (default `redis-cli ping`, which — unlike every
other value — is additionally required to reply exactly `PONG`, preserving
today's stricter check byte-for-byte when the input is left at its default).

Constraints carried over unchanged from ADR 0021 and its #842 amendment:

- **Still `docker exec`, not `services:`.** A `services:` container has no
  `if:` and rejects an empty image, and — per `Verjson/verjson-pg#46` — is
  measured broken on this org's self-hosted lanes regardless (healthy
  service, `ENOTFOUND`/`ECONNREFUSED` from the job). The conditional
  `docker run` this ADR extends exists specifically to route around that.
- **Same first-party caller trust boundary.** `db-health-cmd`/`cache-health-cmd`
  are `workflow_call` inputs set by a first-party Verjson/tequityapp repo's own
  workflow, exactly like `db-image`/`db-env` — not untrusted PR content.
- **Zero behavior change by default.** Every new input defaults to
  reproducing today's exact command, exit-code semantics, and port. A caller
  that sets none of them gets a byte-identical job — pinned by
  `node-ci-db-service.test.sh` and `node-ci-cache-service.test.sh`, whose
  pre-existing assertions (none of which set the new inputs) already prove
  the unset defaults.

### The health command is caller-executable data — bounded, not sandboxed further

A health command is still code the caller controls, executed on the shared
runner's Docker daemon. It is bounded the same way `db-image` itself is
trusted (workflow_call input from a first-party caller), plus one additional
technical constraint: the value is split on whitespace and passed to
`docker exec <container> <tokens...>` as **literal argv — never through a
shell or `eval`**. A `;`, `$()`, or backtick in the value is therefore inert:
it becomes a literal (and likely useless) argument to `docker exec` inside
the target container, not a way to run a second command on the runner
itself. This is a plain-token-replacement choice consistent with `db-env`'s
existing `${DB_PORT}`/`${DB_HOST}` substitution (also literal, also never
`eval`'d) and is pinned by `node-ci-db-service.test.sh`'s and
`node-ci-cache-service.test.sh`'s injection tests, which plant a marker file
via an embedded `; touch <marker>` and assert it is never created. The
tradeoff: no quoting support, so a health command needing an argument that
itself contains whitespace cannot be expressed. That is judged acceptable —
`pg_isready`, `redis-cli ping`, and `cypher-shell -u neo4j -p neo4j 'RETURN
1'`-shaped commands (space-separated, no embedded-whitespace arguments) cover
the engines actually in scope.

A health command that never succeeds fails the step after the same 30-attempt
bound `pg_isready`/`redis-cli ping` always had, naming the image and the
exact command — it cannot hang to the job's `timeout-minutes`.

### Not adopted (yet)

Option 2 (a generic `services:` input) remains the better end state if a
third engine shape shows up that this shape can't express, but is deferred:
it is a materially larger change to a contract every `node` caller depends
on, and option 1 already unblocks the concrete, evidenced need (Neo4j in
`Verjson/verjson-ai`). Revisit if a future consumer needs more than one
non-Postgres/non-Redis service in the same job, or a health check whose
arguments require embedded whitespace.

## Consequences

- `Verjson/verjson-ai` can adopt a Neo4j `db-image` (with `db-port: '7687'`
  and a Bolt-shaped `db-health-cmd`) without a bespoke consumer-side job,
  closing the coverage gap recorded in that repository's ADR-0029 and README.
- The `db-env` hardcoded-port rejection (ADR 0021 / #116) still only
  recognizes the literal `5432`. It is Postgres-specific tooling that stays
  harmless — merely inert, not incorrect — for a caller using a different
  `db-port`; generalizing it is left for when a second `db-port` consumer
  actually needs it.

---
date: 2026-08-22
issue: 986
impact: minor
title: node-ci accepts a caller-supplied health check and container port for db-image/cache-image
---
Canonical Node CI's `db-image`/`cache-image` service slots are no longer
hardwired to Postgres/Redis. New optional inputs `db-health-cmd`, `db-port`, and
`cache-health-cmd` let a caller run any engine's own readiness check (and, for
`db-image`, its own container port) instead of the fixed `pg_isready` /
`redis-cli ping` checks.

Every existing caller is unaffected: the new inputs default to today's exact
checks and port (`pg_isready`, `redis-cli ping`, `5432`), so a caller that
doesn't set them gets byte-identical behaviour. The health command runs only as
literal `docker exec` arguments — never through a shell or `eval` — so it cannot
escape to the runner regardless of its content. ADR 0114 records the design
choice (a caller-supplied command over a generic `services:` list or a third
hardwired slot) and the trust-boundary reasoning.

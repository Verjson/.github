---
date: 2026-07-25
id: 20260726T124511Z
title: node-ci's optional DB service is safe to run twice on one host
---

`node-ci.yml`'s default-off Postgres service bound a fixed host port `5432` and
named its container from `run_id`/`run_attempt` alone, so the second DB-backed job
to land on a self-hosted host could not start: the port was taken and the name was
already in use (#116, an AI-review follow-up from #113). The container now
publishes on an OS-assigned loopback port (`-p 127.0.0.1::5432`) and is named
`ci-postgres-<run_id>-<run_attempt>-<hash of job + runner identity>`. The name is
only for humans reading `docker ps`: the start step publishes the **container ID**
`docker run` returns and drives `docker port`/`exec`/`logs` and the `if: always()`
teardown off that, so a job can never remove a concurrent job's live container
even if two names ever did collide.

Because the host port is no longer known up front, **`db-env` gains a placeholder
contract — a breaking change**. Write `${DB_PORT}` where the port
belongs — `DATABASE_URL=postgres://app:pw@127.0.0.1:${DB_PORT}/app` — and the step
substitutes the port `docker port` reports. Braces are required: a brace-less
`$DB_PORT` fails the step pointing at `${DB_PORT}`, because it has no closing
boundary and `$DB_PORTX` would silently expand to `49187X`. It is a literal token replacement: no
scheme detection, no URL parsing. An earlier attempt inferred the port position by
matching the value's shape and kept producing new bugs — it spliced the DB port
into unrelated URLs on any scheme (`https://internal.svc/v1` →
`https://internal.svc:49187/v1`, `redis://cache/0`, `s3://bucket/key`), corrupted
`postgres://localhost?sslmode=require`, and hard-failed the job for any value
containing `port=<digits>` (`--port=3000`, `--inspect-port=9229`, even
`--report=1`). None of that is reachable now: values without the token are
exported byte-identical, and the token works in IPv6-literal, `jdbc:`, libpq
`host=… port=…`, quoted and `@`-in-password values that the parsing design had to
reject outright. A value that **hardcodes 5432** is rejected by name telling you
to use `${DB_PORT}`, never rewritten behind your back; a `postgres://` URL with no
placeholder is passed through untouched but logs a note, since libpq would default
it to the host's 5432. That rejection matches `port=5432` only as a whole keyword,
so `--report=5432` and `--export=5432` — which contain "port" only by accident,
spelled inside another word — pass through, while `--port=5432`, `--inspect-port=5432`
and a URI's `?port=5432` are still rejected (a dash is a boundary; accepting it
would have to accept a real libpq port too). `DB_PORT` is exported last so a
caller's own `DB_PORT` line can't win the last-wins `$GITHUB_ENV` merge, and a
`db-env` line that is not `KEY=VALUE` now fails the step quoting the line instead of
reaching `$GITHUB_ENV` raw — where the runner's opaque "Invalid format" never
mentioned `db-env`. Blank lines and `#` comments are skipped.

Containers carry `--label verjson-ci=1` and labelled orphans older than 6h are
reaped at start, since an ephemeral port no longer makes a leak self-announcing.
The age bound is computed in-shell from `docker ps --format '{{.ID}} {{.CreatedAt}}'`
because docker has no usable one: `until` is prune-only (`docker ps --filter
until=6h` is a hard `invalid filter` error, which made the first version of this
sweep a silent no-op) and `docker container prune` reaps only stopped containers.
6h is GitHub's default job timeout, so nothing older can belong to a running job —
a concurrent job's live container is never a candidate, and a test now fails if
`node-ci.yml` ever declares a `timeout-minutes` above 360 (a caller can't raise a
reusable's timeout, so that is the only way to break the bound). Listing failures,
unreadable creation times and refused removals all warn rather than pass in silence.

`db-image`, the input names, the default-off behaviour and the caller-supplied
image are unchanged, and a survey of the `Verjson` and `tequityapp` orgs found no
consumer repo passing `db-env` or `db-image` at all, so the contract change breaks
nobody today. Pinned by `scripts/ci-gate/node-ci-db-service.test.sh` (mutation-
checked: 18 deliberate defects, all caught); ADR 0021 is amended rather than
superseded (the concurrency limit was parked there as tracked in #116).

# node-ci's optional DB service is safe to run twice on one host — 2026-07-25

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

Because the host port is no longer known up front, the step reads it back with
`docker port` and rewrites the host port of postgres-scheme `db-env` values (a
`:5432` bounded by `/`, `?` or end-of-value is a placeholder; such a URL with no
port gets one inserted) before exporting them, and exports `$DB_PORT` last so a
caller's own `DB_PORT` line can't win the last-wins `$GITHUB_ENV` merge. A value
that names a database port but cannot be rewritten — IPv6-literal host, quoted
URL, `jdbc:postgresql:`, libpq `host=… port=…` — now **fails the step by name**
instead of silently aiming the caller's suite at whatever else listens on the
host's 5432; `PGPORT` is set to the mapped port; everything else (a REDIS_URL on
any port, including one that starts with 5432) passes through verbatim.
Containers carry `--label verjson-ci=1` and aged labelled orphans are swept at
start, since an ephemeral port no longer makes a leak self-announcing.

The input surface, the default-off behaviour and the caller-supplied image are
unchanged; the `db-env` description now documents exactly which shapes are
rewritten and which are rejected. Pinned by
`scripts/ci-gate/node-ci-db-service.test.sh`; ADR 0021 is amended rather than
superseded (the concurrency limit was parked there as tracked in #116).

# node-ci's optional DB service is safe to run twice on one host — 2026-07-25

`node-ci.yml`'s default-off Postgres service bound a fixed host port `5432` and
named its container from `run_id`/`run_attempt` alone, so the second DB-backed job
to land on a self-hosted host could not start: the port was taken and the name was
already in use (#116, an AI-review follow-up from #113). The container now
publishes on an OS-assigned loopback port (`-p 127.0.0.1::5432`) and is named
`ci-postgres-<run_id>-<run_attempt>-<hash of job + runner identity>` — two
concurrent jobs on one host are always served by two distinct runner processes, so
their names differ; the start step publishes the name as a step output and the
`if: always()` teardown removes exactly that container.

Because the host port is no longer known up front, the step reads it back with
`docker port` and rewrites the host port of URL-shaped `db-env` values (a `:5432`
is now a placeholder; a URL with no port gets one inserted) before exporting them
to `$GITHUB_ENV`, and exports `$DB_PORT` alongside. The input surface, the
default-off behaviour and the caller-supplied image are unchanged, and the
`db-env` description no longer documents the one-DB-job-per-host limitation.
Pinned by `scripts/ci-gate/node-ci-db-service.test.sh`; ADR 0021 is amended rather
than superseded (the concurrency limit was parked there as tracked in #116).

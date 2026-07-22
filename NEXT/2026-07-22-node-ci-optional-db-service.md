# Reusable node-ci gains an optional, default-off Postgres service — 2026-07-22

`node-ci.yml` now accepts optional `db-image` and `db-env` inputs so a
Postgres-backed Node repo (e.g. tequityapp/tequity-api, tequity-worker running
Jest against `pgvector/pgvector:pg16`) can adopt the reusable without re-inlining
checkout/setup-node/test. When `db-image` is empty (the default) nothing changes
for current callers; when set, a conditional `docker run` step starts the image
on port 5432, health-waits with `pg_isready`, passes each `POSTGRES_*` pair into
the container, and exports every `db-env` pair — including `DATABASE_URL` — to
`$GITHUB_ENV` for `npm test`. A `services:` block was avoided because it has no
`if:` toggle and rejects an empty image, so it couldn't be defaulted off without
forcing a DB on every caller. Covered by
`scripts/ci-gate/node-ci-db-service.test.sh` (wired into `actions-ci.yml`). Refs
#108.

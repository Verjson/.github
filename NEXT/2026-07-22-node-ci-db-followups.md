# node-ci DB service: harden teardown test + record the security posture — 2026-07-22

Closes out the AI-review follow-ups from the #113 node-ci DB-service merge.
`scripts/ci-gate/node-ci-db-service.test.sh` now asserts the teardown step
combines `always()` with the `inputs.db-image` guard on the **same** `if:` line
(#115) — a regression dropping the guard (making teardown run unconditionally)
now fails the suite. And [ADR 0021](docs/decisions/0021-node-ci-caller-supplied-db-image/README.md)
records the decision to run a caller-supplied `db-image` on the shared
self-hosted pool and its trust boundary (first-party callers only; #117). The
single-host concurrency limit stays tracked in #116.

# Mark node-ci's statuses permission as startup-required — 2026-07-28

Correct `node-ci.yml` and ADR 0023 to say that callers must grant the reusable
eligibility job's explicit `statuses: read` request. Omitting it fails the called
workflow at startup before the runtime fail-open logic can execute. Extend the
eligibility regression test to keep that caller contract accurate. Closes #148.

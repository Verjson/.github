---
date: 2026-08-05
issue: 118
title: Add a reversible overflow lane for gate jobs that poll the shared pool
---

`ai-review-merge.yml`, `changelog-validate.yml`, and `changelog-release.yml` now consult
`VERJSON_RUNNER_OVERFLOW` ahead of `VERJSON_RUNNER_UNTRUSTED` and `VERJSON_RUNNER_DEFAULT`.
Setting it to `["ubuntu-24.04"]` moves those jobs to hosted runners; deleting the variable
restores the previous routing exactly, with no code change.

ADR 0050 already established that a gate job sleeps while polling for CI it cannot
influence, so on a fixed pool the sleepers starve the CI they wait for — but it applied the
fix only to public targets, and the organization has 2 public repositories against 88
private. Measured on the shared lane: 31,406 s queued against 11,103 s of runtime, with
`gate` and `privileged_merge` together consuming 71% of lane runtime while mostly polling.

When the variable is unset the routing expression behaves exactly as before, so the change
is inert until opted into. See
[ADR 0053](docs/decisions/0053-overflow-lane-for-polling-gate-jobs/README.md).

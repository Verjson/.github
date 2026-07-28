# Pin the removed statuses-permission claim in CI — 2026-07-28

Strengthened the reusable Node permission-contract test to reject the exact
former ADR wording that incorrectly described an absent caller grant as
fail-open, while positively requiring the workflow-startup boundary in both
`node-ci.yml` and ADR 0023 (#148).

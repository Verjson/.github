# Reusable merge gate fails fast on cross-org consumer misconfig — 2026-07-23

Two follow-ups from the #129 gate review. `runner_labels` is now **required**
under `workflow_call`: a consumer org has no runner for Verjson's `self-hosted,gate`
pool, so omitting it silently queued the job forever (#130) — an in-job check
can't catch that (no runner ever starts the step), so the call is now rejected
outright with a clear message. New `require_secrets` preflight step fails closed
early with an actionable message when `ORG_ADMIN_TOKEN` is empty (consumer forgot
`secrets: inherit`, #131) instead of dying later in an opaque `gh` auth error; it
never echoes the token and is a no-op on the org direct paths. Pinned by new
`scripts/ci-gate/require-secrets.test.sh` and an extended `reusable-workflow.test.sh`,
wired into `actions-ci.yml`. ADR 0022 amended. Refs #130, #131.

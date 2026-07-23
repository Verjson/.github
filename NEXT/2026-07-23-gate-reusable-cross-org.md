# Merge gate is now a pinnable cross-org reusable workflow — 2026-07-23

`ai-review-merge.yml` gained a `workflow_call` trigger alongside its existing
`pull_request` (org ruleset) and `workflow_dispatch` (operator) paths, so
consumers in other orgs pin `uses: Verjson/.github/.github/workflows/ai-review-merge.yml@v1`
with `secrets: inherit` instead of hand-copying and drifting (the #38 casualty).
Both jobs' `runs-on` now prefer a `runner_labels` input, falling back to the
unchanged self-gate `meta`/`gate` split (ADR 0016) on the org direct paths. The
`target_guard` (#119, ADR 0020) is unchanged and auto-bounds each consumer to its
own org via `GITHUB_REPOSITORY_OWNER` under `workflow_call`. New
`scripts/ci-gate/reusable-workflow.test.sh` pins these seams; wired into
`actions-ci.yml`. Manual prerequisite before any cross-org caller works: widen
Verjson/.github → Settings → Actions → Access to the enterprise. Refs #128,
ADR 0022; follow-up migration of Tequity's copies tracked from
`tequityapp/tequity-platform#38`.

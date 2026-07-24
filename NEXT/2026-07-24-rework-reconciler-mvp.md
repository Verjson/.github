# Rework-telemetry reconciler (MVP) — 2026-07-24

Implements the MVP slice of #33 (ADR 0006 observe-and-report; ADR 0007 blast-radius
verification). A weekly, retrospective reconciler measures rework on merged PRs —
reverts, fix-follows-merge, pre-merge friction — split by `change_category` ×
`ai_authored`, and opens a **summary issue that only proposes** where human
verification should be heavier. It never touches a merge/verification gate: the
workflow's sole write is `gh issue create`, and its permissions are
`contents: read` + `issues: write` (asserted by a governance-guard test).

Design: two cheap GitHub-API calls per repo (`gh pr list` cheap fields + a
default-branch `gh api …/commits` for the squash-commit `(#NN)` ref and
`Co-Authored-By: Claude` trailer), joined locally, then three **pure,
fixture-tested** stages — classify → aggregate → report. The aggregate conforms to
`ReworkTelemetryPayload` (verjson-observability#49), so the later OTLP path is
additive. No OTLP dependency (collector still dormant per `docs/ci-telemetry.md`).

The dial is **human-owned**: thresholds + repo list live in
`.telemetry/rework-thresholds.json`; the reconciler only reads it. Per ADR 0006
this component stays human-reviewed — the PR is flagged accordingly and must not
be auto-merged without a human signing off on the attribution logic and floors.

Files: `.github/workflows/rework-reconcile.yml`, `scripts/ci-telemetry/rework-{classify,aggregate,report,reconcile}.sh`
(+ `*.test.sh`), `.telemetry/rework-thresholds.json`, `docs/rework-telemetry.md`.
Known MVP gaps (documented, all fail toward less confidence): `post_merge_ci_fail`
and `file_overlap_only` not yet populated; `fix_same_area` is the coarse proxy for
"same-area within N days"; `commits_after_first_review` is 0 under squash.

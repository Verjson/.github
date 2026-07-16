# CI telemetry for the AI review/merge gate

The org-wide AI review/merge gate (`.github/workflows/ai-review-merge.yml`)
emits bounded, best-effort telemetry about each review through the shared
`verjson-observability` OTLP pipeline.

## Design

- The `ai-review` job builds one `CiTelemetryPayload` (the schema defined in
  `verjson-observability`) from runtime facts it already owns.
- It is emitted with the `Verjson/verjson-observability` composite action
  (`@v0.7.2`), which runs `emit-ci-telemetry.cjs` and exports OTLP metrics to
  the shared collector. There is no bespoke HTTP/curl path.
- Every telemetry step is `continue-on-error: true` and `if: always()`, so a
  telemetry fault can **never** fail or block the gate.
- It is **dormant until an endpoint exists**: the composite action no-ops when
  `OTEL_EXPORTER_OTLP_ENDPOINT` is unset. Provision that secret (plus
  `OTEL_EXPORTER_OTLP_HEADERS` for auth) to turn it on.

## What is emitted (the `ai-review` payload)

Schema-conformant `CiTelemetryPayload` fields: `repository`, `workflow_name`,
`job_name`, `event_name`, `lane`, `review_type`, `lane_reason`,
`model_selected`, `budget_usd`, `dependency_major`, `verdict_blocking`,
`findings_count`, `action_conclusion`, `execution_file_present`,
`execution_file_parse_ok`, `total_cost_usd`, `total_turns`.

Numeric/status fields sourced from Claude's `execution_file` are extracted
defensively by `scripts/ci-telemetry/parse-claude-execution.sh` (present/parse
flags, `num_turns`, `total_cost_usd`, `subtype`) — never the transcript itself.

## What is explicitly excluded

Prompt text, diff text, PR review/findings text, raw Claude transcript, exact
error text, PR title/body, and the full file list. Only bounded numeric and
enumerated fields leave the runner.

## Extending

`classify` and `ai-merge` telemetry can be added the same way (build a
`CiTelemetryPayload`, emit via the composite action, keep every step
`continue-on-error`). Only `ai-review` is wired today to keep the surface
minimal.

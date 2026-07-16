# 0004 — Merge-gate CI telemetry via the verjson-observability action

- **Date:** 2026-07-15
- **PR:** Verjson/.github#20 (rewritten on branch `agent/ci-telemetry-gate`)
- **Category:** CI merge gate + cross-repo action dependency + org Actions
  access setting (sensitive-class)

## Context

An earlier draft of #20 added telemetry to the gate as an **independent**
implementation: it built custom JSON and POSTed it via raw `curl` to a
`CI_TELEMETRY_ENDPOINT` secret, ignoring the org's existing telemetry
infrastructure. It had three problems: it conflicted with the post-escalation
gate (ADR 0002); its `Build`/`Export` steps were `if: always()` but **not**
`continue-on-error`, so a jq fault could fail an already-approved `ai-review`
job and block merges org-wide; and it emitted to a non-existent endpoint, never
reaching the `verjson-observability` OTLP collector.

`verjson-observability` already ships a composite action (`emit-ci-telemetry`,
best-effort, never fails the workflow) and a `CiTelemetryPayload` schema.

## Decision

Rewrite #20 to use the standard path:

1. **Resolved the conflict** onto the current escalation-based gate.
2. **Emit via `uses: Verjson/verjson-observability@v0.7.2`** (payload-file
   input) instead of curl. Deleted `scripts/ci-telemetry/export-payload.sh`;
   kept `parse-claude-execution.sh` to extract `num_turns`/`total_cost_usd`/
   `subtype` from Claude's `execution_file`.
3. **Reshaped the payload** to the real `CiTelemetryPayload` schema
   (`repository`, `workflow_name`, `job_name`, `lane`, `model_selected`,
   `verdict_blocking`, `findings_count`, `total_cost_usd`, `total_turns`, …).
4. **Every telemetry step is `continue-on-error`** (and `if: always()`), so
   telemetry can never fail or block the gate.
5. **Enabled cross-repo action access:** set
   `verjson-observability` Actions `access_level` to `organization` (was
   `none`) so the gate can resolve the action. Applied via REST API.

Scope kept minimal: only the `ai-review` job emits today (richest data);
`classify`/`ai-merge` can follow the same pattern.

## Consequences

- Telemetry is standard, safe, and **dormant**: the composite action no-ops
  until `OTEL_EXPORTER_OTLP_ENDPOINT` (+ `OTEL_EXPORTER_OTLP_HEADERS`) is
  provisioned as a secret. Turning it on is a secret change, no code change.
- The gate now depends on `verjson-observability@v0.7.2` being resolvable —
  hence the `access_level: organization` setting (sensitive org change, flagged
  here).
- The prior gate-breaking risk (unguarded `if: always()` telemetry) is removed.

## Follow-up

- Provision `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS` (org or
  `.github` repo secrets) pointing at the collector reachable from the GCP
  self-hosted runners, to activate telemetry.

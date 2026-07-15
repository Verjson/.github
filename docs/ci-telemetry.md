# CI telemetry for the AI review/merge gate

This repo emits bounded workflow telemetry for the org-wide AI review/merge
gate in `.github/workflows/ai-review-merge.yml`.

Current design:

- telemetry is produced inside the workflow, where the gate owns the runtime
  facts
- Claude `structured_output` is the stable verdict surface
- Claude `execution_file` is treated as implementation-backed and parsed
  defensively for numeric/status fields only
- export is best-effort and must never flip a passing gate red

What is emitted

- `classify` payload
  - lane
  - lane reason
  - selected model
  - configured budget
  - dependency-major flag
  - bounded PR size metadata

- `ai-review` payload
  - CI wait duration
  - review duration
  - verdict blocking flag
  - findings count
  - self-approval fallback usage
  - Claude action outcome
  - safe execution-file summary fields:
    - `duration_ms`
    - `num_turns`
    - `total_cost_usd`
    - `is_error`
    - `subtype`

- `ai-merge` payload
  - lane
  - merge wait duration
  - merge outcome
  - failure stage if merge is blocked

What is explicitly excluded

- prompt text
- diff text
- PR review body
- findings text
- raw Claude transcript
- exact error text
- PR title/body
- full file list

Export behavior

- Each job writes a JSON payload under `.telemetry/`.
- Each payload is uploaded as a short-retention artifact.
- If `CI_TELEMETRY_ENDPOINT` is configured, the payload is POSTed as JSON.
- `CI_TELEMETRY_AUTH_HEADER` can supply one extra header, for example
  `Authorization: Bearer ...`.
- Export failures are logged and ignored.

Remaining dependency on `verjson-observability`

- Replace the temporary HTTP export hook with the shared emitter/contract once
  that repo ships the CI telemetry surface.
- Keep the payload schema aligned with the observability-side allowlist and
  metric-label rules.

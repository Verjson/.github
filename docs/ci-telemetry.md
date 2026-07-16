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

## Provisioning the OTLP exporter (how to turn telemetry on)

Telemetry is dormant until two secrets exist. **But setting them is step 2 —
step 1 is making the collector reachable from the runners.** Read the
reachability section first.

### 1. Reachability prerequisite (do this first)

The shared collector is deployed **in-cluster** by `verjson-infra`'s
`ObservabilityStack` (namespace `observability`, service `otel-collector`), and
is **ClusterIP-only**:

- OTLP HTTP: `http://otel-collector.observability.svc.cluster.local:4318`
- OTLP gRPC: `http://otel-collector.observability.svc.cluster.local:4317`

That `*.svc.cluster.local` name resolves **only inside the Kubernetes cluster**.
The AI-gate jobs run on the **self-hosted GCP runners**, which are
docker-compose containers on GCE VMs (`Verjson/github-runner-docker-compose`) —
**outside** the cluster. They cannot resolve cluster DNS or route to a ClusterIP,
so the in-cluster URL will not work from CI as-is.

Pick one path to bridge that gap (infra work in `verjson-infra`, not a secret):

1. **Expose the collector on an internal LoadBalancer** (recommended). Add an
   internal-LB `Service` (GCP annotation
   `networking.gke.io/load-balancer-type: "Internal"`) for `otel-collector`'s
   `4318` port, and ensure the runners' VMs are on the same VPC/subnet. Then the
   endpoint is `http://<internal-lb-ip-or-dns>:4318`.
2. **Move the runners in-cluster** (actions-runner-controller pods). Then the
   ClusterIP DNS endpoint above works directly with no exposure change.
3. Any equivalent VPC-routable path (peering + `ExternalName`, etc.).

Until one exists, leave the secrets unset — the gate stays green and telemetry
no-ops.

### 2. Set the secrets

Only the gate emits, so scoping the secrets to `Verjson/.github` is sufficient
and least-privilege (use `--org Verjson` if you want them org-wide later):

```bash
# Base OTLP/HTTP URL of the reachable collector (no path — the SDK appends
# /v1/metrics). Use the HTTP receiver (4318), not gRPC.
gh secret set OTEL_EXPORTER_OTLP_ENDPOINT --repo Verjson/.github \
  --body 'http://<collector-host>:4318'

# Optional auth: newline-separated `Name: value` headers.
printf 'Authorization: Bearer %s\n' "$TOKEN" | \
  gh secret set OTEL_EXPORTER_OTLP_HEADERS --repo Verjson/.github
```

- Use **HTTP (4318)**, not gRPC — the composite action's CLI speaks OTLP/HTTP.
- Prefer **TLS** (`https://…`) if the path crosses anything untrusted; rotate the
  bearer token by re-setting `OTEL_EXPORTER_OTLP_HEADERS`.
- Omit `OTEL_EXPORTER_OTLP_HEADERS` if the internal LB is on a trusted network
  and the collector is unauthenticated.

### 3. Verify

Trigger a gate run (open a trivial PR, or `workflow_dispatch` the gate), then
confirm arrival at the collector:

```bash
kubectl -n observability logs deploy/otel-collector | grep -i verjson.cicd
```

or look for `verjson.cicd.*` metrics in Grafana. The `Emit ai-review telemetry`
step logs a warning (never fails) if export is rejected.

## Extending

`classify` and `ai-merge` telemetry can be added the same way (build a
`CiTelemetryPayload`, emit via the composite action, keep every step
`continue-on-error`). Only `ai-review` is wired today to keep the surface
minimal.

#!/usr/bin/env bash
set -euo pipefail

payload_path="${1:-}"

if [ -z "$payload_path" ] || [ ! -f "$payload_path" ]; then
  echo "ci-telemetry: payload missing, skipping export" >&2
  exit 0
fi

if ! jq -e . "$payload_path" >/dev/null 2>&1; then
  echo "ci-telemetry: payload is not valid JSON, skipping export" >&2
  exit 0
fi

endpoint="${CI_TELEMETRY_ENDPOINT:-}"
if [ -z "$endpoint" ]; then
  echo "ci-telemetry: CI_TELEMETRY_ENDPOINT not configured, skipping export" >&2
  exit 0
fi

curl_args=(
  --silent
  --show-error
  --fail-with-body
  --max-time "${CI_TELEMETRY_TIMEOUT_SECONDS:-10}"
  -H "Content-Type: application/json"
  --data-binary "@${payload_path}"
)

if [ -n "${CI_TELEMETRY_AUTH_HEADER:-}" ]; then
  curl_args+=(-H "${CI_TELEMETRY_AUTH_HEADER}")
fi

if ! curl "${curl_args[@]}" "$endpoint"; then
  echo "ci-telemetry: export failed, leaving workflow green" >&2
fi

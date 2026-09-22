#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$root/.github/workflows/app-key-environment.yml" "$tmp/validate-key.sh" <<'PY'
import sys
from pathlib import Path

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
step = next(
    step
    for step in workflow["jobs"]["validate-ai-review-key"]["steps"]
    if step.get("name") == "Validate resolved AI review App private key"
)
Path(sys.argv[2]).write_text(step["run"] + "\n", encoding="utf-8")
PY

run_validator() {
  local key="$1"
  RUNNER_TEMP="$tmp" AI_REVIEW_APP_PRIVATE_KEY="$key" bash "$tmp/validate-key.sh"
}

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$tmp/key.pem" 2>/dev/null
valid_key="$(<"$tmp/key.pem")"
run_validator "$valid_key"

if run_validator '' >"$tmp/empty.log" 2>&1; then
  echo 'empty AI_REVIEW_APP_PRIVATE_KEY unexpectedly passed' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/empty.log"

if run_validator 'not private key' >"$tmp/invalid.log" 2>&1; then
  echo 'malformed AI_REVIEW_APP_PRIVATE_KEY unexpectedly passed' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/invalid.log"
if grep -q 'not private key' "$tmp/invalid.log"; then
  echo 'validator leaked the supplied private key' >&2
  exit 1
fi

openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/public.pem"
public_key="$(<"$tmp/public.pem")"
if run_validator "$public_key" >"$tmp/public.log" 2>&1; then
  echo 'public key unexpectedly passed as a private key' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/public.log"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/ec-key.pem" 2>/dev/null
ec_key="$(<"$tmp/ec-key.pem")"
if run_validator "$ec_key" >"$tmp/ec.log" 2>&1; then
  echo 'EC key unexpectedly passed as an RSA private key' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/ec.log"

printf '%s\n' 'PASS - reusable App-key policy accepts valid RSA keys and rejects empty, malformed, public, and non-RSA keys without leaking input'

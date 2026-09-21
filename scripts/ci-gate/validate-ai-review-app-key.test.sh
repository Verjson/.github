#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$tmp/key.pem" 2>/dev/null
valid_key="$(<"$tmp/key.pem")"

AI_REVIEW_APP_PRIVATE_KEY="$valid_key" bash "$root/scripts/ci-gate/validate-ai-review-app-key.sh"

if AI_REVIEW_APP_PRIVATE_KEY='' bash "$root/scripts/ci-gate/validate-ai-review-app-key.sh" >"$tmp/empty.log" 2>&1; then
  echo 'empty AI_REVIEW_APP_PRIVATE_KEY unexpectedly passed' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/empty.log"

if AI_REVIEW_APP_PRIVATE_KEY='not a private key' bash "$root/scripts/ci-gate/validate-ai-review-app-key.sh" >"$tmp/invalid.log" 2>&1; then
  echo 'malformed AI_REVIEW_APP_PRIVATE_KEY unexpectedly passed' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/invalid.log"
if grep -q 'not a private key' "$tmp/invalid.log"; then
  echo 'validator echoed the private-key input' >&2
  exit 1
fi

openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/public.pem"
public_key="$(<"$tmp/public.pem")"
if AI_REVIEW_APP_PRIVATE_KEY="$public_key" bash "$root/scripts/ci-gate/validate-ai-review-app-key.sh" >"$tmp/public.log" 2>&1; then
  echo 'public key unexpectedly passed as a private key' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/public.log"

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ec-key.pem"
ec_key="$(<"$tmp/ec-key.pem")"
if AI_REVIEW_APP_PRIVATE_KEY="$ec_key" bash "$root/scripts/ci-gate/validate-ai-review-app-key.sh" >"$tmp/ec.log" 2>&1; then
  echo 'EC AI_REVIEW_APP_PRIVATE_KEY unexpectedly passed' >&2
  exit 1
fi
grep -q 'AI_REVIEW_APP_PRIVATE_KEY' "$tmp/ec.log"

echo 'AI review App private-key validation: ok'

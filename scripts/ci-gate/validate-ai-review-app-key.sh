#!/usr/bin/env bash
set -euo pipefail

key="${AI_REVIEW_APP_PRIVATE_KEY:-}"
if [ -z "$key" ]; then
  echo "::error::AI_REVIEW_APP_PRIVATE_KEY is empty or unavailable" >&2
  exit 1
fi

umask 077
key_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ai-review-app-key.XXXXXX")"
trap 'rm -f "$key_file"' EXIT
printf '%s' "$key" >"$key_file"
unset key

if ! openssl rsa -in "$key_file" -check -noout >/dev/null 2>&1; then
  echo "::error::AI_REVIEW_APP_PRIVATE_KEY is not a valid PEM RSA private key" >&2
  exit 1
fi

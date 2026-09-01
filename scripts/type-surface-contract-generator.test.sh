#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
generator="$root/scripts/gen-type-surface-contract.sh"
ref="$(git -C "$root" rev-parse HEAD)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts"
"$generator" pack-helper "$ref" >"$tmp/scripts/npm-pack-json.mjs"
"$generator" contract-test "$ref" >"$tmp/scripts/type-surface-contract-contract.test.sh"
chmod +x "$tmp/scripts/type-surface-contract-contract.test.sh"

cmp -s "$root/scripts/npm-pack-json.mjs" "$tmp/scripts/npm-pack-json.mjs"
bash "$tmp/scripts/type-surface-contract-contract.test.sh"

printf '\n// drift\n' >>"$tmp/scripts/npm-pack-json.mjs"
if bash "$tmp/scripts/type-surface-contract-contract.test.sh" >/dev/null 2>&1; then
  echo 'FAIL - generated contract test accepted a modified parser' >&2
  exit 1
fi

if "$generator" pack-helper main >/dev/null 2>&1; then
  echo 'FAIL - generator accepted a mutable contract ref' >&2
  exit 1
fi

echo 'ok - type-surface generator emits a byte-identical helper and pinning contract test'

#!/usr/bin/env bash
# Enforces the organization-owned Renovate policy boundary (Verjson/.github#699).
set -uo pipefail

die() { printf 'renovate-config-conformance: %s\n' "$1" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      [ "$#" -ge 2 ] || die '--repo-root requires a value'
      root="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -d "$root" ] || die "repository root is not a directory: $root"

findings=0
for path in \
  renovate.json \
  renovate.json5 \
  .github/renovate.json \
  .github/renovate.json5 \
  .renovaterc \
  .renovaterc.json \
  .renovaterc.json5; do
  if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
    printf 'renovate-config-conformance: repository-level %s overrides organization Renovate policy\n' "$path" >&2
    findings=$((findings + 1))
  fi
done

if [ -e "$root/package.json" ] || [ -L "$root/package.json" ]; then
  [ -f "$root/package.json" ] || die 'package.json is not a regular file'
  jq -e 'type == "object" and has("renovate")' "$root/package.json" >/dev/null 2>&1
  status=$?
  case "$status" in
    0)
      printf 'renovate-config-conformance: repository-level package.json#renovate overrides organization Renovate policy\n' >&2
      findings=$((findings + 1))
      ;;
    1) ;;
    *) die 'package.json is not valid JSON' ;;
  esac
fi

[ "$findings" -eq 0 ]

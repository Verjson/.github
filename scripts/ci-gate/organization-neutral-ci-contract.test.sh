#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

legacy_prefix="VERJSON_"
contract_paths=(.github scripts docs)

find_legacy_context_refs() {
  rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
    "(vars|secrets)\\.${legacy_prefix}[A-Z0-9_]+" "$@" || true
  rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
    "(vars|secrets)\\\\\\.${legacy_prefix}[A-Z0-9_]+" "$@" || true
  rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
    "(vars|secrets)\\[[[:space:]]*['\"]${legacy_prefix}[A-Z0-9_]+['\"][[:space:]]*\\]" "$@" || true
}

legacy_context_refs="$(find_legacy_context_refs "${contract_paths[@]}")"
[ -z "$legacy_context_refs" ] || {
  printf 'organization-branded GitHub configuration remains:\n%s\n' "$legacy_context_refs" >&2
  exit 1
}

fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  "vars['${legacy_prefix}LANE_TRUSTED']" \
  "vars[\"${legacy_prefix}LANE_TRUSTED\"]" \
  "secrets['${legacy_prefix}RELEASE_TOKEN']" \
  "secrets[\"${legacy_prefix}RELEASE_TOKEN\"]" >"$fixture"
[ "$(find_legacy_context_refs "$fixture" | wc -l)" -eq 4 ] || {
  echo 'bracket-form neutrality mutations were not all rejected' >&2
  exit 1
}

for legacy_secret in "${legacy_prefix}RUNNER_DEPLOY_TOKEN" "${legacy_prefix}RELEASE_TOKEN"; do
  refs="$(
    rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
      "$legacy_secret" "${contract_paths[@]}" || true
  )"
  [ -z "$refs" ] || {
    printf 'organization-branded secret contract remains:\n%s\n' "$refs" >&2
    exit 1
  }
done

grep -qF 'vars.CI_LANE_PRIVILEGED' scripts/gen-privileged-merge-caller.sh
grep -qF 'vars.CI_RUNNER_DEFAULT' scripts/gen-changelog-caller.sh
grep -qF 'secrets.RELEASE_TOKEN' scripts/gen-container-release.sh
grep -qF 'secrets.RUNNER_DEPLOY_TOKEN' .github/workflows/container-deployment.yml

printf 'organization-neutral canonical CI variable contract: PASS\n'

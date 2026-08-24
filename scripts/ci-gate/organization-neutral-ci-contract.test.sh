#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

legacy_prefix="VERJSON_"
contract_paths=(.github scripts docs)

scan_pattern() {
  local pattern=$1
  shift
  local output status
  output="$(mktemp)"
  if grep -rInE "$pattern" "$@" >"$output"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -gt 1 ]; then
    rm -f "$output"
    return "$status"
  fi
  grep -v '^docs/decisions/' "$output" || true
  rm -f "$output"
}

find_legacy_context_refs() {
  scan_pattern "(vars|secrets)\\.${legacy_prefix}[A-Z0-9_]+" "$@" || return $?
  scan_pattern "(vars|secrets)\\\\\\.${legacy_prefix}[A-Z0-9_]+" "$@" || return $?
  scan_pattern "(vars|secrets)\\[[[:space:]]*['\"]${legacy_prefix}[A-Z0-9_]+['\"][[:space:]]*\\]" "$@" || return $?
}

legacy_context_refs="$(find_legacy_context_refs "${contract_paths[@]}")"
[ -z "$legacy_context_refs" ] || {
  printf 'organization-branded GitHub configuration remains:\n%s\n' "$legacy_context_refs" >&2
  exit 1
}

fixture_dir="$(mktemp -d)"
fixture="$fixture_dir/bracket-forms.yml"
trap 'rm -rf "$fixture_dir"' EXIT
printf '%s\n' \
  "vars['${legacy_prefix}LANE_TRUSTED']" \
  "vars[\"${legacy_prefix}LANE_TRUSTED\"]" \
  "secrets['${legacy_prefix}RELEASE_TOKEN']" \
  "secrets[\"${legacy_prefix}RELEASE_TOKEN\"]" >"$fixture"
[ "$(find_legacy_context_refs "$fixture" | wc -l)" -eq 4 ] || {
  echo 'bracket-form neutrality mutations were not all rejected' >&2
  exit 1
}
mkdir -p "$fixture_dir/scripts/decisions"
printf '%s\n' "vars.${legacy_prefix}LANE_TRUSTED" > "$fixture_dir/scripts/decisions/active.yml"
[ "$(find_legacy_context_refs "$fixture_dir/scripts" | wc -l)" -eq 1 ] || {
  echo 'an active nested decisions directory bypassed the neutrality guard' >&2
  exit 1
}
if find_legacy_context_refs "$fixture_dir/missing" >/dev/null 2>&1; then
  echo 'a missing scan root was reported as clean' >&2
  exit 1
fi

for legacy_secret in "${legacy_prefix}RUNNER_DEPLOY_TOKEN" "${legacy_prefix}RELEASE_TOKEN"; do
  refs="$(
    scan_pattern "$legacy_secret" "${contract_paths[@]}"
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

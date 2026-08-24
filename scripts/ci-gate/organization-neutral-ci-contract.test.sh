#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

legacy_prefix="VERJSON_"
contract_paths=(.github scripts docs)

legacy_context_refs="$(
  rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
    "(vars|secrets)\\.${legacy_prefix}[A-Z0-9_]+" "${contract_paths[@]}" || true
)"
[ -z "$legacy_context_refs" ] || {
  printf 'organization-branded GitHub configuration remains:\n%s\n' "$legacy_context_refs" >&2
  exit 1
}

legacy_escaped_refs="$(
  rg -n --glob '!docs/decisions/**' --glob '!CHANGELOG/**' --glob '!NEXT/**' \
    "vars\\\\\\.${legacy_prefix}[A-Z0-9_]+" "${contract_paths[@]}" || true
)"
[ -z "$legacy_escaped_refs" ] || {
  printf 'organization-branded escaped variable matcher remains:\n%s\n' "$legacy_escaped_refs" >&2
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

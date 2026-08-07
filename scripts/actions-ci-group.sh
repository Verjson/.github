#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="${ACTIONS_CI_GROUP_MANIFEST:-$root/scripts/actions-ci-groups.tsv}"
group="${1-}"

case "$group" in
  platform|merge-gate|changelog-release) ;;
  *)
    printf 'unknown actions-ci group: %s\n' "$group" >&2
    exit 2
    ;;
esac

[ -r "$manifest" ] || {
  printf 'actions-ci group manifest is unreadable: %s\n' "$manifest" >&2
  exit 2
}

cd "$root" || exit 2
failures=0
commands=0
while IFS=$'\t' read -r command_group command; do
  case "$command_group" in
    ''|\#*) continue ;;
  esac
  [ "$command_group" = "$group" ] || continue
  commands=$((commands + 1))
  printf '::group::%s\n' "$command"
  if bash -o pipefail -c "$command"; then
    printf '::endgroup::\n'
  else
    status=$?
    printf '::error::group=%s command=%q exit=%d\n' "$group" "$command" "$status"
    printf '::endgroup::\n'
    failures=$((failures + 1))
  fi
done <"$manifest"

if [ "$commands" -eq 0 ]; then
  printf 'actions-ci group has no commands: %s\n' "$group" >&2
  exit 2
fi
if [ "$failures" -ne 0 ]; then
  printf '%d command(s) failed in actions-ci group %s\n' "$failures" "$group" >&2
  exit 1
fi

printf 'actions-ci group %s passed %d command(s)\n' "$group" "$commands"

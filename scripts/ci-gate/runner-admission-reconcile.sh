#!/usr/bin/env bash
# Reconcile ADR 0035 variable-driven lanes against live runner-group admission
# and online capacity. Exit 0 is proven clean, 1 is drift, and 2 means the live
# state could not be determined.
set -uo pipefail

ORG="${ORG:-Verjson}"
GENERAL_GROUP_ID="${GENERAL_GROUP_ID:-4}"
UNTRUSTED_GROUP_ID="${UNTRUSTED_GROUP_ID:-6}"

die_undetermined() {
  printf 'UNDETERMINED: %s\n' "$1" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || die_undetermined "gh is not available"
command -v jq >/dev/null 2>&1 || die_undetermined "jq is not available"

fetch() {
  local path="$1" jq_expr="$2" out
  if ! out="$(gh api --paginate "$path" --jq "$jq_expr" 2>&1)"; then
    printf 'UNDETERMINED: GET %s failed: %s\n' \
      "$path" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

repos_raw="$(fetch "/orgs/$ORG/repos?per_page=100" \
  '.[] | select(.archived == false) | "\(.full_name)\t\(.private)"')" || exit 2
[ -n "${repos_raw//[[:space:]]/}" ] \
  || die_undetermined "no active repositories returned for org $ORG"

default_var="$(fetch "/orgs/$ORG/actions/variables/VERJSON_RUNNER_DEFAULT" \
  '{value,visibility}')" || exit 2
untrusted_var="$(fetch "/orgs/$ORG/actions/variables/VERJSON_RUNNER_UNTRUSTED" \
  '{value,visibility}')" || exit 2

selector() {
  local name="$1" variable="$2" value visibility
  value="$(jq -er '.value' <<<"$variable")" \
    || die_undetermined "$name has no string value"
  visibility="$(jq -er '.visibility' <<<"$variable")" \
    || die_undetermined "$name has no visibility"
  [ "$visibility" = "all" ] \
    || die_undetermined "$name is not visible to all repositories"
  jq -e 'type == "array" and length >= 2 and .[0] == "self-hosted"
    and all(.[]; type == "string" and length > 0)' <<<"$value" >/dev/null \
    || die_undetermined "$name is not a non-empty JSON label array beginning with self-hosted"
  printf '%s\n' "$value"
}

default_selector="$(selector VERJSON_RUNNER_DEFAULT "$default_var")" || exit 2
untrusted_selector="$(selector VERJSON_RUNNER_UNTRUSTED "$untrusted_var")" || exit 2

general_group="$(fetch "/orgs/$ORG/actions/runner-groups/$GENERAL_GROUP_ID" \
  '{id,name,visibility,allows_public_repositories}')" || exit 2
untrusted_group="$(fetch "/orgs/$ORG/actions/runner-groups/$UNTRUSTED_GROUP_ID" \
  '{id,name,visibility,allows_public_repositories}')" || exit 2
general_members="$(fetch "/orgs/$ORG/actions/runner-groups/$GENERAL_GROUP_ID/repositories?per_page=100" \
  '[.repositories[].full_name]')" || exit 2
untrusted_members="$(fetch "/orgs/$ORG/actions/runner-groups/$UNTRUSTED_GROUP_ID/repositories?per_page=100" \
  '[.repositories[].full_name]')" || exit 2
general_runners="$(fetch "/orgs/$ORG/actions/runner-groups/$GENERAL_GROUP_ID/runners?per_page=100" \
  '[.runners[] | {name,status,labels:[.labels[].name]}]')" || exit 2
untrusted_runners="$(fetch "/orgs/$ORG/actions/runner-groups/$UNTRUSTED_GROUP_ID/runners?per_page=100" \
  '[.runners[] | {name,status,labels:[.labels[].name]}]')" || exit 2

group_for_selector() {
  local labels="$1"
  if jq -e 'index("lane-general") != null or index("general") != null' <<<"$labels" >/dev/null; then
    printf 'general\n'
  elif jq -e 'index("lane-untrusted") != null or index("isolated") != null
    or index("untrusted-pr") != null' <<<"$labels" >/dev/null; then
    printf 'untrusted\n'
  else
    die_undetermined "selector has no governed lane label: $labels"
  fi
}

admitted() {
  local repo="$1" private="$2" group="$3" members="$4"
  local visibility allows_public
  visibility="$(jq -r '.visibility' <<<"$group")"
  allows_public="$(jq -r '.allows_public_repositories' <<<"$group")"
  case "$visibility" in
    all)
      [ "$private" = "true" ] || [ "$allows_public" = "true" ]
      ;;
    selected)
      jq -e --arg repo "$repo" 'index($repo) != null' <<<"$members" >/dev/null \
        && { [ "$private" = "true" ] || [ "$allows_public" = "true" ]; }
      ;;
    *)
      return 1
      ;;
  esac
}

has_capacity() {
  local labels="$1" runners="$2"
  jq -e --argjson required "$labels" '
    any(.[]; . as $runner | .status == "online" and
      ($required | all(. as $required_label |
        ($runner.labels | index($required_label)) != null)))
  ' <<<"$runners" >/dev/null
}

default_lane="$(group_for_selector "$default_selector")" || exit 2
untrusted_lane="$(group_for_selector "$untrusted_selector")" || exit 2
drift=""
count=0

while IFS=$'\t' read -r repo private; do
  [ -n "$repo" ] || continue
  count=$((count + 1))
  if [ "$private" = "true" ]; then
    lane="$default_lane"
  else
    lane="$untrusted_lane"
  fi
  case "$lane" in
    general) group="$general_group"; members="$general_members"; group_id="$GENERAL_GROUP_ID" ;;
    untrusted) group="$untrusted_group"; members="$untrusted_members"; group_id="$UNTRUSTED_GROUP_ID" ;;
  esac
  admitted "$repo" "$private" "$group" "$members" \
    || drift="$drift- \`$repo\` cannot access runner group $group_id for the selected $lane lane"$'\n'
done <<EOF
$repos_raw
EOF

[ "$count" -gt 0 ] || die_undetermined "parsed zero repositories"

case "$default_lane" in
  general) default_runners="$general_runners" ;;
  untrusted) default_runners="$untrusted_runners" ;;
esac
case "$untrusted_lane" in
  general) untrusted_runners_for_selector="$general_runners" ;;
  untrusted) untrusted_runners_for_selector="$untrusted_runners" ;;
esac

has_capacity "$default_selector" "$default_runners" \
  || drift="$drift- VERJSON_RUNNER_DEFAULT has no matching online runner"$'\n'
has_capacity "$untrusted_selector" "$untrusted_runners_for_selector" \
  || drift="$drift- VERJSON_RUNNER_UNTRUSTED has no matching online runner"$'\n'

printf '## Runner admission reconciliation (%s)\n\n' "$ORG"
printf 'Checked **%d** active repositories using variable-selected default and untrusted lanes.\n\n' "$count"

if [ -n "$drift" ]; then
  printf '### Drift\n\n%s\n' "$drift"
  exit 1
fi

printf 'No drift: variables are valid, every repository is admitted, and both lanes have online capacity.\n'

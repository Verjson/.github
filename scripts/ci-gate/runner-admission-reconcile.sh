#!/usr/bin/env bash
# Reconcile ADR 0035 variable-driven lanes against live runner-group admission
# and online capacity. Exit 0 is proven clean, 1 is drift, and 2 means the live
# state could not be determined.
set -uo pipefail

ORG="${ORG:-Verjson}"
# Groups are resolved by NAME against the live listing, never by a pinned id.
# Ids are not stable over an org's lifetime: group 6 (`isolated`) was deleted on
# 2026-07-31 and this job went undetermined on every run afterwards (#266). The
# names stay overridable so a rename is a config change, not a code change.
GENERAL_GROUP_NAME="${GENERAL_GROUP_NAME:-GCP}"
UNTRUSTED_GROUP_NAME="${UNTRUSTED_GROUP_NAME:-isolated}"

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

# One listing, slurped: `--paginate` emits one object per page, so streaming
# `.runner_groups[]` and slurping is the pagination-safe shape (cf. #260).
groups_ndjson="$(fetch "/orgs/$ORG/actions/runner-groups?per_page=100" \
  '.runner_groups[]')" || exit 2
groups="$(jq -sc '.' <<<"$groups_ndjson")" \
  || die_undetermined "runner group listing for $ORG was not JSON"
jq -e 'length > 0' <<<"$groups" >/dev/null \
  || die_undetermined "no runner groups returned for org $ORG"

lane_group_name() {
  case "$1" in
    general) printf '%s\n' "$GENERAL_GROUP_NAME" ;;
    untrusted) printf '%s\n' "$UNTRUSTED_GROUP_NAME" ;;
    *) die_undetermined "no runner group is configured for lane '$1'" ;;
  esac
}

# Fail closed, and say WHICH group — the id-in-a-URL message this replaces did
# not identify the group, which is what made the outage hard to read.
resolve_group() {
  local lane="$1" name group
  name="$(lane_group_name "$lane")" || exit 2
  group="$(jq -c --arg name "$name" \
    'map(select(.name == $name)) | .[0] // empty' <<<"$groups")" \
    || die_undetermined "could not search runner groups for '$name'"
  [ -n "$group" ] || die_undetermined \
    "runner group '$name' (selected by the $lane lane) does not exist in $ORG; present groups: $(jq -r 'map(.name) | join(", ")' <<<"$groups")"
  printf '%s\n' "$group"
}

# Resolve only the groups a lane actually selects. A group nothing routes to is
# not this job's business and must not be able to take the run down — that is
# precisely how a deleted, unreferenced `isolated` group blinded the monitor.
general_group=""
untrusted_group=""
for lane in "$default_lane" "$untrusted_lane"; do
  case "$lane" in
    general)
      [ -n "$general_group" ] || { general_group="$(resolve_group general)" || exit 2; } ;;
    untrusted)
      [ -n "$untrusted_group" ] || { untrusted_group="$(resolve_group untrusted)" || exit 2; } ;;
    # Total only because group_for_selector is — an invariant 80 lines away.
    # Without this arm a new lane silently resolves NO group, and the omission
    # surfaces later as an unhandled lane in the repository loop. Failing here
    # names the real cause instead of at the point of use.
    *) die_undetermined "unhandled lane '$lane' while resolving runner groups" ;;
  esac
done

# `--paginate` concatenates one response PER PAGE, so a `[...]` collector yields
# one array per page and the `jq -e` in admitted()/has_capacity() would reflect
# only the LAST page — a repository listed on page 1 would read as unadmitted
# and be reported as drift against a healthy org (same class as #260). Stream
# the elements and slurp them into a single array instead.
slurp_strings() { jq -Rsc 'split("\n") | map(select(length > 0))'; }
slurp_objects() { jq -sc '.'; }

group_id_of() {
  # `.id // empty` rather than `.id | tostring`: tostring turns a MISSING id into
  # the literal string "null" and exits 0, which builds `/runner-groups/null/...`
  # and only fails closed by accident when the API 404s. `// empty` produces no
  # output, so jq -e exits 4 and the guard below actually fires.
  jq -er '.id // empty' <<<"$1" \
    || die_undetermined "runner group object has no id: $1"
}

general_id=""
general_members='[]'
general_runners='[]'
if [ -n "$general_group" ]; then
  general_id="$(group_id_of "$general_group")" || exit 2
  general_members="$(fetch "/orgs/$ORG/actions/runner-groups/$general_id/repositories?per_page=100" \
    '.repositories[].full_name' | slurp_strings)" || exit 2
  general_runners="$(fetch "/orgs/$ORG/actions/runner-groups/$general_id/runners?per_page=100" \
    '.runners[] | {name,status,labels:[.labels[].name]}' | slurp_objects)" || exit 2
fi

untrusted_id=""
untrusted_members='[]'
untrusted_runners='[]'
if [ -n "$untrusted_group" ]; then
  untrusted_id="$(group_id_of "$untrusted_group")" || exit 2
  untrusted_members="$(fetch "/orgs/$ORG/actions/runner-groups/$untrusted_id/repositories?per_page=100" \
    '.repositories[].full_name' | slurp_strings)" || exit 2
  untrusted_runners="$(fetch "/orgs/$ORG/actions/runner-groups/$untrusted_id/runners?per_page=100" \
    '.runners[] | {name,status,labels:[.labels[].name]}' | slurp_objects)" || exit 2
fi

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
    general) group="$general_group"; members="$general_members"
             group_label="$GENERAL_GROUP_NAME (id $general_id)" ;;
    untrusted) group="$untrusted_group"; members="$untrusted_members"
             group_label="$UNTRUSTED_GROUP_NAME (id $untrusted_id)" ;;
    # Without this, an unhandled lane silently reuses the PREVIOUS iteration's
    # group/members and misattributes drift to the wrong group.
    *) die_undetermined "unhandled lane '$lane' for repository $repo" ;;
  esac
  admitted "$repo" "$private" "$group" "$members" \
    || drift="$drift- \`$repo\` cannot access runner group $group_label for the selected $lane lane"$'\n'
done <<EOF
$repos_raw
EOF

[ "$count" -gt 0 ] || die_undetermined "parsed zero repositories"

case "$default_lane" in
  general) default_runners="$general_runners" ;;
  untrusted) default_runners="$untrusted_runners" ;;
  *) die_undetermined "unhandled default lane '$default_lane'" ;;
esac
case "$untrusted_lane" in
  general) untrusted_runners_for_selector="$general_runners" ;;
  untrusted) untrusted_runners_for_selector="$untrusted_runners" ;;
  *) die_undetermined "unhandled untrusted lane '$untrusted_lane'" ;;
esac

has_capacity "$default_selector" "$default_runners" \
  || drift="$drift- VERJSON_RUNNER_DEFAULT has no matching online runner"$'\n'
has_capacity "$untrusted_selector" "$untrusted_runners_for_selector" \
  || drift="$drift- VERJSON_RUNNER_UNTRUSTED has no matching online runner"$'\n'

# Placement (#275). The two checks above ask whether repositories are admitted
# and whether lanes have capacity. A runner registered WITHOUT `--runnergroup`
# is neither: it lands in GitHub's default group — `visibility: all`,
# `allows_public_repositories: true`, no label discipline — as capacity that no
# lane selects and no policy governs. Nothing detected that before.
#
# Resolved by `.default`, never by the id 1. The id is stable in practice, but
# pinning an id is exactly what took this job down for a week (#266), and the
# flag is what the invariant is actually about.
default_group="$(jq -c 'map(select(.default == true)) | .[0] // empty' <<<"$groups")" \
  || die_undetermined "could not search runner groups for the default group"
[ -n "$default_group" ] || die_undetermined \
  "no runner group in $ORG is marked default; GitHub always marks exactly one and a custom group cannot become it (ADR 0003), so this listing is not what it should be: $(jq -r 'map(.name) | join(", ")' <<<"$groups")"

default_group_id="$(group_id_of "$default_group")" || exit 2
default_group_name="$(jq -er '.name // empty' <<<"$default_group")" \
  || die_undetermined "default runner group has no name: $default_group"

# Fetched unconditionally, and a failure here exits 2. Treating an unreadable
# group as empty would turn this check into a rubber stamp — the fail-open shape
# #266 left in this file.
stray_ndjson="$(fetch "/orgs/$ORG/actions/runner-groups/$default_group_id/runners?per_page=100" \
  '.runners[] | {name,status}')" || exit 2
stray_runners="$(slurp_objects <<<"$stray_ndjson")" \
  || die_undetermined "default runner group listing for $ORG was not JSON"

# Names are selected HERE rather than in the API-side `--jq`, because the test
# stub returns fixtures verbatim and cannot exercise a server-side filter: a
# mutation adding `select(.status == "online")` to that expression passed the
# whole suite. Anything this check's correctness depends on has to be evaluated
# on data the tests actually control.
#
# And no status filter, deliberately: an offline runner is still registered in
# the wrong group and rejoins the pool on its own.
strays="$(jq -c 'map(.name)' <<<"$stray_runners")" \
  || die_undetermined "could not read runner names from the default group listing"

if jq -e 'length > 0' <<<"$strays" >/dev/null; then
  drift="$drift- runner(s) sit in the default group \`$default_group_name\` (id $default_group_id), which admits public repositories and enforces no labels: $(jq -r 'join(", ")' <<<"$strays"). Register with \`--runnergroup\`; provisioning lives in verjson-cli-cloud"$'\n'
fi

printf '## Runner admission reconciliation (%s)\n\n' "$ORG"
printf 'Checked **%d** active repositories using variable-selected default and untrusted lanes.\n\n' "$count"

if [ -n "$drift" ]; then
  printf '### Drift\n\n%s\n' "$drift"
  exit 1
fi

printf 'No drift: variables are valid, every repository is admitted, both lanes have online capacity, and no runner sits in the default group `%s`.\n' \
  "$default_group_name"

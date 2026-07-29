#!/usr/bin/env bash
# Reconcile ADR 0033 runner routing against live org runner-group admission.
#
# Routing decides a lane from repository visibility; only org settings decide
# whether a repository can actually be ASSIGNED that lane. Nothing keeps the two
# honest, which is how #182 and #192 happened and why a newly created repository
# still queues forever with no check run (#189). This detects that divergence
# instead of waiting for someone's PR to hang.
#
# Exit codes are the contract:
#   0  every active repository can be assigned the lane routing would pick
#   1  drift found — report on stdout names the repositories
#   2  could not determine — API failure, missing token, or an empty/unparseable
#      response. NEVER conflated with 0: "I could not look" is not "all clear".
set -uo pipefail

ORG="${ORG:-Verjson}"
GENERAL_GROUP_ID="${GENERAL_GROUP_ID:-4}"
ISOLATED_GROUP_ID="${ISOLATED_GROUP_ID:-6}"

die_undetermined() {
  printf 'UNDETERMINED: %s\n' "$1" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || die_undetermined "gh is not available"
command -v jq >/dev/null 2>&1 || die_undetermined "jq is not available"

# Reading org runner groups needs org scope; the default GITHUB_TOKEN is
# repo-scoped and returns 403 here — reported as undetermined rather than as a
# clean org we never actually read.
#
# Returns non-zero rather than calling die_undetermined: every caller runs this
# in a command substitution, and `exit` inside `$( )` only ends the SUBSHELL.
# Exiting here left the parent running with empty membership and reporting
# *drift* for an org it had failed to read — a clean-looking wrong answer, which
# is the one outcome a reconciler must never produce.
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

general_members="$(fetch "/orgs/$ORG/actions/runner-groups/$GENERAL_GROUP_ID/repositories?per_page=100" \
  '.repositories[].full_name')" || exit 2
isolated_members="$(fetch "/orgs/$ORG/actions/runner-groups/$ISOLATED_GROUP_ID/repositories?per_page=100" \
  '.repositories[].full_name')" || exit 2

# An empty membership list is legitimate for a group nobody has onboarded yet,
# but both being empty means we almost certainly read the wrong thing.
if [ -z "${general_members//[[:space:]]/}" ] && [ -z "${isolated_members//[[:space:]]/}" ]; then
  die_undetermined "both runner groups returned no repositories — refusing to report this as clean"
fi

admitted() { printf '%s\n' "$2" | grep -qxF "$1"; }

unassignable=""   # would queue forever: routing picks a lane the repo cannot use
public_on_general="" # public repo admitted to the persistent pool
count=0

while IFS=$'\t' read -r repo private; do
  [ -n "$repo" ] || continue
  count=$((count + 1))
  if [ "$private" = "true" ]; then
    # Tier 3 — private repositories route to the general self-hosted pool.
    admitted "$repo" "$general_members" \
      || unassignable="$unassignable- \`$repo\` (private → general pool, not in runner group $GENERAL_GROUP_ID)"$'\n'
  else
    # Tier 4 — public repositories route to the ephemeral untrusted-PR pool.
    admitted "$repo" "$isolated_members" \
      || unassignable="$unassignable- \`$repo\` (public → isolated pool, not in runner group $ISOLATED_GROUP_ID)"$'\n'
    # Not a hang, but the boundary ADR 0033 depends on: public code must not be
    # assignable to the persistent pool. `allows_public_repositories: false` is
    # what blocks it today; membership here means only that setting stands
    # between fork code and the credentialed runners.
    admitted "$repo" "$general_members" \
      && public_on_general="$public_on_general- \`$repo\` is public AND in runner group $GENERAL_GROUP_ID"$'\n'
  fi
done <<EOF
$repos_raw
EOF

[ "$count" -gt 0 ] || die_undetermined "parsed zero repositories from a non-empty response"

printf '## Runner admission reconciliation (%s)\n\n' "$ORG"
printf 'Checked **%d** active repositories against runner groups %s (general) and %s (isolated).\n\n' \
  "$count" "$GENERAL_GROUP_ID" "$ISOLATED_GROUP_ID"

status=0

if [ -n "$unassignable" ]; then
  status=1
  printf '### Cannot be assigned the lane routing picks\n\n'
  printf 'These repositories emit jobs no runner will ever claim. The job does not\n'
  printf 'fail — it queues with **no check run at all**, and the merge gate waits out\n'
  printf 'its timeout (#182, #192). Admit each to the named group, or make the\n'
  printf 'visibility match the lane it should use.\n\n%s\n' "$unassignable"
fi

if [ -n "$public_on_general" ]; then
  printf '### Public repositories admitted to the persistent pool\n\n'
  printf 'Not currently exploitable — `allows_public_repositories: false` on the\n'
  printf 'group is what prevents assignment. But it means one org setting is the\n'
  printf 'only thing keeping fork code off runners that hold ambient credentials\n'
  printf '(ADR 0033). Remove the admission unless it is deliberate.\n\n%s\n' "$public_on_general"
fi

if [ "$status" -eq 0 ] && [ -z "$public_on_general" ]; then
  printf 'No drift: every active repository is admitted to the group its visibility routes it to.\n'
fi

exit "$status"

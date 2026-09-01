#!/usr/bin/env bash
# ADR 0156: strengthens the standard pre-merge assertion
#   gh pr view N --json statusCheckRollup --jq \
#     '[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'
# which cannot tell a Renovate stability-window deferral (#1219) from a real
# pass, because the deferred `build-test` job still concludes `success`.
#
# Prints "true" and exits 0 only when the rollup is passing AND no completed
# check run at the PR head carries a deferral annotation. Any other outcome
# is a fault: exit non-zero with a `::error::`, never a bare "false".
set -euo pipefail

usage() { echo "usage: $0 <owner/repo> <pr-number>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
repo="$1"
pr="$2"
[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ "$pr" =~ ^[0-9]+$ ]] || usage

deferred_pattern="${DEFERRED_CHECK_ANNOTATION_PATTERN:-^CI deferred$}"

pr_json="$(gh pr view "$pr" --repo "$repo" --json headRefOid,statusCheckRollup)" || {
  echo "::error::failed to fetch PR metadata for $repo#$pr" >&2
  exit 1
}
head_sha="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::could not resolve a head SHA for $repo#$pr" >&2
  exit 1
}

jq -e '
  (.statusCheckRollup | length) > 0 and
  ([.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED"))
' <<<"$pr_json" >/dev/null || {
  echo "::error::$repo#$pr statusCheckRollup is empty, pending, or has a non-passing conclusion" >&2
  exit 1
}

check_run_ids="$(gh api --paginate "repos/$repo/commits/$head_sha/check-runs?per_page=100" \
  | jq -s '[.[].check_runs[] | select(.conclusion != null) | .id] | unique | .[]')" || {
  echo "::error::failed to fetch check runs for $repo@$head_sha" >&2
  exit 1
}

deferred=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  titles="$(gh api --paginate "repos/$repo/check-runs/$id/annotations?per_page=100" \
    | jq -s -r --arg pat "$deferred_pattern" '
        [.[][] | select(.title != null and (.title | test($pat))) | .title] | join(", ")
      ')" || {
    echo "::error::failed to fetch annotations for check-run $id on $repo" >&2
    exit 1
  }
  if [ -n "$titles" ]; then
    deferred="${deferred:+$deferred; }check-run $id: $titles"
  fi
done <<<"$check_run_ids"

if [ -n "$deferred" ]; then
  echo "::error::$repo#$pr head $head_sha carries deferred/unexercised checks: $deferred" >&2
  exit 1
fi

echo true

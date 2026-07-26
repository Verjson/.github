#!/usr/bin/env bash
# MVP rework reconciler (issue #33), per ADR 0006 (observe-and-report). Pure
# GitHub-API: for each repo in the human-owned config, gather merged PRs in the
# window, classify + aggregate rework signals, and print a Markdown summary to
# stdout (the weekly issue body). No OTLP dependency — the MVP shortcut from the
# ticket. If $REWORK_AGG_OUT is set, the raw aggregate JSON is written there for
# the future verjson-observability#49 emit path.
#
# This is the ONLY IO layer. It reads and proposes (its output is a summary issue
# the workflow opens). It NEVER merges, edits, labels, or otherwise mutates any
# PR or gate — the component is read-and-report by construction.
#
# Two cheap calls per repo, joined locally (no per-PR round-trips, no GraphQL
# node-limit blow-up):
#   1. `gh pr list` cheap fields (NOT `commits` — its nested `authors` connection
#      exceeds GitHub's GraphQL node ceiling at any useful --limit).
#   2. `gh api .../commits` on the default branch. The org squash-merges, so each
#      merged PR is one commit whose message carries the `(#NN)` back-reference
#      and the `Co-Authored-By: Claude` trailer — that is the AI-authorship signal.
#
# Fetch integrity: a governance report that silently read empty on an API error
# would understate rework, so calls retry and any repo that still fails is
# SURFACED as a data-quality warning rather than dropped to a clean zero.
set -euo pipefail

cfg="${1:?usage: rework-reconcile.sh <thresholds.json>}"
here="$(cd "$(dirname "$0")" && pwd)"

window_days="$(jq -r '.window_days // 7' "$cfg")"
window_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
window_start="$(date -u -d "-${window_days} days" +%Y-%m-%dT%H:%M:%SZ)"
start_date="$(date -u -d "-${window_days} days" +%Y-%m-%d)"

mapfile -t repos < <(jq -r '.repos[]?' "$cfg")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Retry a gh command (args after $1) into file $1; succeed only on valid JSON.
gh_json() {
  local out="$1"; shift
  local attempt
  for attempt in 1 2; do
    if "$@" >"$out" 2>/dev/null && jq -e . "$out" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

agg='[]'
failed_repos=()    # bulk PR list unreadable -> repo skipped entirely
degraded_repos=()  # commits unreadable -> AI-authorship unreliable for that repo

for repo in "${repos[@]}"; do
  [ -n "$repo" ] || continue

  if ! gh_json "$tmp/bulk.json" gh pr list --repo "$repo" --state merged --limit 200 \
        --search "merged:>=${start_date}" \
        --json number,title,body,mergedAt,createdAt,files,labels,reviews; then
    failed_repos+=("$repo")
    continue
  fi

  # Default-branch commits since the window start (paginated into one array).
  if gh api --paginate "repos/${repo}/commits?since=${window_start}&per_page=100" 2>/dev/null \
      | jq -s 'add // []' >"$tmp/commits.json" 2>/dev/null && jq -e . "$tmp/commits.json" >/dev/null 2>&1; then
    :
  else
    printf '[]' >"$tmp/commits.json"
    degraded_repos+=("$repo")
  fi

  records="$(jq --slurpfile commits "$tmp/commits.json" --arg ws "$window_start" '
    def refs($m): [ $m | scan("\\(#([0-9]+)\\)") | .[0] | tonumber ];
    ($commits[0] // []
      | map({ message: .commit.message, refs: refs(.commit.message) })) as $idx
    | map(
        select(.mergedAt >= $ws)
        | .number as $n
        | ($idx | map(select(.refs | index($n))) | first) as $mc
        | {
            number, title, body,
            files: [.files[]?.path],
            labels: [.labels[]?.name],
            commit_messages: (if $mc then [$mc.message] else [] end),
            review_rounds: ([.reviews[]? | select((.state // "") != "PENDING")] | length),
            changes_requested: ([.reviews[]? | select((.state // "") == "CHANGES_REQUESTED")] | length),
            commits_after_first_review: 0,
            time_open_s: ((.mergedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)),
            post_merge_ci_failed: null,
            file_overlap_only: false
          })' "$tmp/bulk.json")"

  repo_agg="$(printf '%s' "$records" \
    | "$here/rework-classify.sh" \
    | "$here/rework-aggregate.sh" "$repo" "$window_start" "$window_end" "$window_days")"

  agg="$(jq -n --argjson a "$agg" --argjson b "$repo_agg" '$a + $b')"
done

if [ -n "${REWORK_AGG_OUT:-}" ]; then
  printf '%s\n' "$agg" >"$REWORK_AGG_OUT"
fi

# Data-quality banner first, so a partial run is never mistaken for a clean zero.
if [ "${#failed_repos[@]}" -gt 0 ] || [ "${#degraded_repos[@]}" -gt 0 ]; then
  printf '> ⚠️ **Data quality:** '
  [ "${#failed_repos[@]}" -gt 0 ] && printf 'skipped %d unreadable repo(s): %s. ' "${#failed_repos[@]}" "${failed_repos[*]}"
  [ "${#degraded_repos[@]}" -gt 0 ] && printf 'commit data unavailable for %d repo(s) (%s) — AI-authorship there is understated. ' "${#degraded_repos[@]}" "${degraded_repos[*]}"
  printf 'Figures below are partial.\n\n'
fi

printf '%s' "$agg" | "$here/rework-report.sh" "$cfg"

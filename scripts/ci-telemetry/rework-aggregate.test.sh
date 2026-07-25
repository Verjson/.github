#!/usr/bin/env bash
# Behavioural tests for rework-aggregate.sh: per-bucket counts, rework_rate
# (headline excludes file_overlap), and median friction. Fixture-driven.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
aggregate="$here/rework-aggregate.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

enriched='[
  {"number":1,"change_category":"app","ai_authored":true,"rework_signal":null,"post_merge_ci_fail":false,"file_overlap_only":false,"review_rounds":1,"changes_requested":0,"commits_after_first_review":0,"time_open_s":100},
  {"number":2,"change_category":"app","ai_authored":true,"rework_signal":"revert","post_merge_ci_fail":false,"file_overlap_only":false,"review_rounds":3,"changes_requested":1,"commits_after_first_review":2,"time_open_s":300},
  {"number":3,"change_category":"app","ai_authored":true,"rework_signal":"fix_same_area","post_merge_ci_fail":false,"file_overlap_only":false,"review_rounds":2,"changes_requested":0,"commits_after_first_review":1,"time_open_s":200},
  {"number":4,"change_category":"docs","ai_authored":false,"rework_signal":null,"post_merge_ci_fail":false,"file_overlap_only":true,"review_rounds":0,"changes_requested":0,"commits_after_first_review":0,"time_open_s":50}
]'

out="$(printf '%s' "$enriched" | "$aggregate" Verjson/x 2026-07-01T00:00:00Z 2026-07-08T00:00:00Z 7)"

app='.[] | select(.change_category=="app" and .ai_authored==true)'
docs='.[] | select(.change_category=="docs")'

check() { # desc, jqfilter, expected
  local got
  got="$(printf '%s' "$out" | jq -c "$2")"
  [ "$got" = "$3" ] && pass "$1" || fail "$1 (want $3, got $got)"
}

check "app/AI merged_count"    "($app) | .merged_count" 3
check "app/AI rework_count"    "($app) | .rework_count" 2
check "app/AI rework_rate"     "($app) | .rework_rate" 0.6667
check "app/AI revert tally"    "($app) | .rework_by_signal.revert" 1
check "app/AI fix_same_area"   "($app) | .rework_by_signal.fix_same_area" 1
check "app/AI review_rounds_p50 (median 1,2,3)" "($app) | .review_rounds_p50" 2
check "app/AI time_open_s_p50 (median 100,200,300)" "($app) | .time_open_s_p50" 200
check "app/AI commits_after_first_review_p50 (median 0,1,2)" "($app) | .commits_after_first_review_p50" 1
check "app/AI window carried"  "($app) | .window_days" 7
check "docs merged_count"      "($docs) | .merged_count" 1
check "docs rework_count is 0" "($docs) | .rework_count" 0
check "docs overlap excluded from rework but counted" "($docs) | .file_overlap_only" 1
check "docs rework_rate is 0"  "($docs) | .rework_rate" 0

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1

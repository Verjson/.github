#!/usr/bin/env bash
# Behavioural tests for rework-report.sh: a bucket over its warn floor with
# enough sample is PROPOSED; small samples and quiet weeks are not; the report
# always carries the observe-and-report disclaimer. Fixture-driven.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
report="$here/rework-report.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

agg='[
  {"repository":"Verjson/x","window_start":"2026-07-01T00:00:00Z","window_end":"2026-07-08T00:00:00Z","window_days":7,"change_category":"app","ai_authored":true,"merged_count":3,"rework_count":2,"rework_rate":0.6667,"rework_by_signal":{"revert":1,"explicit_fix_ref":0,"fix_same_area":1,"post_merge_ci_fail":0},"file_overlap_only":0,"review_rounds_p50":2,"time_open_s_p50":200,"changes_requested_p50":0,"commits_after_first_review_p50":1,"sample_size":3}
]'

# --- breach flagged when sample >= min_sample and rate > floor ---
cat >"$tmp/warn.json" <<'JSON'
{ "min_sample": 1, "rework_rate_warn": { "default": 0.5, "app": 0.5 } }
JSON
out="$(printf '%s' "$agg" | "$report" "$tmp/warn.json")"
grep -q "Verjson/x · app · AI" <<<"$out" && pass "over-floor bucket is proposed" || fail "expected a proposal for app/AI"
grep -q "Observe-and-report only" <<<"$out" && pass "carries observe-and-report disclaimer" || fail "missing disclaimer"

# --- no breach when sample below min_sample (small-N honesty) ---
cat >"$tmp/highmin.json" <<'JSON'
{ "min_sample": 10, "rework_rate_warn": { "default": 0.5, "app": 0.5 } }
JSON
out="$(printf '%s' "$agg" | "$report" "$tmp/highmin.json")"
grep -q "_None this window._" <<<"$out" && pass "small sample not flagged" || fail "small-N should not be flagged"

# --- no breach when rate under floor ---
cat >"$tmp/highfloor.json" <<'JSON'
{ "min_sample": 1, "rework_rate_warn": { "default": 0.9, "app": 0.9 } }
JSON
out="$(printf '%s' "$agg" | "$report" "$tmp/highfloor.json")"
grep -q "_None this window._" <<<"$out" && pass "under-floor rate not flagged" || fail "under-floor should not be flagged"

# --- empty week renders cleanly ---
out="$(printf '[]' | "$report" "$tmp/warn.json")"
grep -q "No merged PRs found" <<<"$out" && pass "empty window renders no-data line" || fail "empty window handling"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1

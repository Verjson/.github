#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
validator="$here/validate-review-verdict.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
accepts() { bash "$validator" "$1" "${2:-false}"; }

exact='{"blocking":true,"summary":"test","review_first":[{"location":"a","why":"b"}],"findings":[],"followups":[]}'
if accepts "$exact"; then fail "exact empty-findings regression payload is rejected"; else pass "exact empty-findings regression payload is rejected"; fi

valid='{"blocking":true,"summary":"unsafe null handling","review_first":[{"location":"src/load.ts:42","why":"load-bearing parser"}],"findings":[{"location":"src/load.ts:42","reason":"null is dereferenced","failure_scenario":"an empty response crashes the worker"}],"followups":[]}'
accepts "$valid" && pass "actionable blocking verdict is accepted" || fail "actionable blocking verdict is accepted"

placeholder='{"blocking":false,"summary":"safe","review_first":[{"location":"a","why":"b"}],"findings":[],"followups":[]}'
if accepts "$placeholder" true; then fail "sensitive placeholder location is rejected"; else pass "sensitive placeholder location is rejected"; fi

empty_sensitive='{"blocking":false,"summary":"safe","review_first":[],"findings":[],"followups":[]}'
if accepts "$empty_sensitive" true; then fail "sensitive verdict requires review-first location"; else pass "sensitive verdict requires review-first location"; fi
accepts "$empty_sensitive" false && pass "low-risk non-blocking verdict may omit review-first" || fail "low-risk non-blocking verdict may omit review-first"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."

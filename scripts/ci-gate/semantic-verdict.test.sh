#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workflow="$here/../../.github/workflows/ai-review-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mapfile -t validators < <(grep 'if jq -e --argjson sensitive' "$workflow")
if [ "${#validators[@]}" -ne 3 ]; then
  echo "FAIL - expected exactly three semantic validator commands"
  exit 1
fi
if [ "${validators[0]}" != "${validators[1]}" ] || [ "${validators[0]}" != "${validators[2]}" ]; then
  echo "FAIL - per-pass semantic validators have drifted"
  exit 1
fi
filter=$(sed -E "s/.*--argjson sensitive [^ ]+ '(.*)' <<<.*/\\1/" <<<"${validators[0]}")
accepts() { jq -e --argjson sensitive "${2:-false}" "$filter" <<<"$1" >/dev/null; }

exact='{"blocking":true,"summary":"test","review_first":[{"location":"a","why":"b"}],"findings":[],"followups":[]}'
if accepts "$exact"; then fail "exact empty-findings regression payload is rejected"; else pass "exact empty-findings regression payload is rejected"; fi

valid='{"blocking":true,"summary":"unsafe null handling","review_first":[{"location":"src/load.ts:42","why":"load-bearing parser"}],"findings":[{"location":"src/load.ts:42","reason":"null is dereferenced","failure_scenario":"an empty response crashes the worker"}],"followups":[]}'
accepts "$valid" && pass "actionable blocking verdict is accepted" || fail "actionable blocking verdict is accepted"

nonblocking_findings='{"blocking":false,"summary":"claims safe","review_first":[],"findings":[{"location":"src/load.ts:42","reason":"null is dereferenced","failure_scenario":"an empty response crashes the worker"}],"followups":[]}'
if accepts "$nonblocking_findings"; then fail "non-blocking verdict with findings is rejected"; else pass "non-blocking verdict with findings is rejected"; fi

placeholder='{"blocking":false,"summary":"safe","review_first":[{"location":"a","why":"b"}],"findings":[],"followups":[]}'
if accepts "$placeholder" true; then fail "sensitive placeholder location is rejected"; else pass "sensitive placeholder location is rejected"; fi

empty_sensitive='{"blocking":false,"summary":"safe","review_first":[],"findings":[],"followups":[]}'
if accepts "$empty_sensitive" true; then fail "sensitive verdict requires review-first location"; else pass "sensitive verdict requires review-first location"; fi
accepts "$empty_sensitive" false && pass "low-risk non-blocking verdict may omit review-first" || fail "low-risk non-blocking verdict may omit review-first"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."

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

mapfile -t normalizers < <(grep 'normalized="$(jq -c' "$workflow")
if [ "${#normalizers[@]}" -ne 3 ]; then
  echo "FAIL - expected exactly three review-first normalizers"
  exit 1
fi
if [ "${normalizers[0]}" != "${normalizers[1]}" ] || [ "${normalizers[0]}" != "${normalizers[2]}" ]; then
  echo "FAIL - per-pass review-first normalizers have drifted"
  exit 1
fi
normalizer=$(sed -E "s/.*jq -c '(.*)' <<<.*/\\1/" <<<"${normalizers[0]}")
normalize() { jq -c "$normalizer" <<<"$1"; }

[ "$(grep -cF 'Every review_first.location MUST contain exactly one file and one' "$workflow")" -eq 1 ] \
  && [ "$(grep -cF 'no ranges or comma-separated locations.' "$workflow")" -eq 3 ] \
  && pass "prompt and every schema require exactly one file:line review-first location" \
  || fail "prompt and every schema require exactly one file:line review-first location"

[ "$(grep -cF 'field=review_first.location expected=path/to/file.ext:42' "$workflow")" -eq 3 ] \
  && pass "every semantic retry identifies the invalid field and expected shape" \
  || fail "every semantic retry identifies the invalid field and expected shape"

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

ranged='{"blocking":false,"summary":"safe","review_first":[{"location":"scripts/release-verify.sh:4-6","why":"release boundary"}],"findings":[],"followups":[]}'
normalized=$(normalize "$ranged")
[ "$(jq -r '.review_first[0].location' <<<"$normalized")" = "scripts/release-verify.sh:4" ] && accepts "$normalized" true \
  && pass "review-first range deterministically normalizes to its first line" \
  || fail "review-first range deterministically normalizes to its first line"

multiple='{"blocking":false,"summary":"safe","review_first":[{"location":"scripts/release-verify.test.sh:10-14,24-25,47-48","why":"coverage"}],"findings":[],"followups":[]}'
normalized=$(normalize "$multiple")
[ "$(jq -r '.review_first[0].location' <<<"$normalized")" = "scripts/release-verify.test.sh:10" ] && accepts "$normalized" true \
  && pass "comma-separated review-first locations normalize to the first line" \
  || fail "comma-separated review-first locations normalize to the first line"

blocking_range='{"blocking":true,"summary":"unsafe","review_first":[{"location":"src/load.ts:40-44","why":"parser"}],"findings":[{"location":"src/load.ts:42-43","reason":"bad","failure_scenario":"crash"}],"followups":[]}'
normalized=$(normalize "$blocking_range")
if accepts "$normalized"; then
  fail "normalization does not weaken blocking finding location semantics"
else
  pass "normalization does not weaken blocking finding location semantics"
fi

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."

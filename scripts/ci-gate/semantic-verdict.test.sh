#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workflow="$here/../../.github/workflows/ai-review-merge.yml"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

mapfile -t validators < <(grep 'if jq -e --argjson sensitive' "$workflow")
if [ "${#validators[@]}" -ne 1 ]; then
  echo "FAIL - expected exactly one semantic validator command"
  exit 1
fi
filter=$(sed -E "s/.*--argjson sensitive [^ ]+ '(.*)' <<<.*/\\1/" <<<"${validators[0]}")
accepts() { jq -e --argjson sensitive "${2:-false}" "$filter" <<<"$1" >/dev/null; }

mapfile -t normalizers < <(grep 'normalized="$(jq -c' "$workflow")
if [ "${#normalizers[@]}" -ne 1 ]; then
  echo "FAIL - expected exactly one review-first normalizer"
  exit 1
fi
normalizer=$(sed -E "s/.*jq -c '(.*)' <<<.*/\\1/" <<<"${normalizers[0]}")
normalize() { jq -c "$normalizer" <<<"$1"; }

[ "$(grep -cF 'Every review_first.location MUST contain exactly one file and one' "$workflow")" -eq 1 ] \
  && [ "$(grep -cF 'no ranges or comma-separated locations.' "$workflow")" -eq 1 ] \
  && pass "prompt and schema require exactly one file:line review-first location" \
  || fail "prompt and schema require exactly one file:line review-first location"

[ "$(grep -cF 'field=review_first.location expected=path/to/file.ext:42' "$workflow")" -eq 1 ] \
  && pass "semantic failure identifies the invalid field and expected shape" \
  || fail "semantic failure identifies the invalid field and expected shape"

mapfile -t schemas < <(grep -- '--json-schema' "$workflow")
if [ "${#schemas[@]}" -ne 1 ]; then
  echo "FAIL - expected exactly one action-level verdict schema"
  exit 1
fi
schema_admits_review_first_location() {
  jq -e --arg candidate "$2" '
    .properties.review_first.items.properties.location as $location
    | ($location.type == "string")
      and (($location.pattern? // "") == "" or ($candidate | test($location.pattern)))
  ' <<<"$1" >/dev/null
}
all_schemas_admit_review_first_location() {
  local candidate="$1" schema_line schema
  for schema_line in "${schemas[@]}"; do
    schema=$(sed -E "s/.*--json-schema '([^']+)'.*/\\1/" <<<"$schema_line")
    schema_admits_review_first_location "$schema" "$candidate" || return 1
  done
}

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
all_schemas_admit_review_first_location "$(jq -r '.review_first[0].location' <<<"$ranged")" \
  && pass "action schema admits a ranged review-first location for deterministic repair" \
  || fail "action schema admits a ranged review-first location for deterministic repair"
normalized=$(normalize "$ranged")
[ "$(jq -r '.review_first[0].location' <<<"$normalized")" = "scripts/release-verify.sh:4" ] && accepts "$normalized" true \
  && pass "review-first range deterministically normalizes to its first line" \
  || fail "review-first range deterministically normalizes to its first line"

multiple='{"blocking":false,"summary":"safe","review_first":[{"location":"scripts/release-verify.test.sh:10-14,24-25,47-48","why":"coverage"}],"findings":[],"followups":[]}'
all_schemas_admit_review_first_location "$(jq -r '.review_first[0].location' <<<"$multiple")" \
  && pass "action schema admits comma-separated review-first locations for deterministic repair" \
  || fail "action schema admits comma-separated review-first locations for deterministic repair"
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

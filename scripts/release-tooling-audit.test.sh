#!/usr/bin/env bash
# Unit tests for scripts/release-tooling-audit.sh (Verjson/.github#146, #89).
# The wrapper replaced a bare `npm audit --audit-level=high`, so it now owns the
# org's release-tooling supply-chain gate: a regression here either wedges every
# PR in the org (false positive) or silently lets a high/critical advisory
# through (false negative). Tests drive the REAL script against a stubbed
# `npm audit --json` — never the network — and assert it fails CLOSED on every
# way the report can be unreadable. Plain bash + jq, no test framework, so it
# runs on the bare self-hosted pool.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/release-tooling-audit.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stubbed `npm`: replays a canned report from $STUB_NPM_JSON and exits with
# $STUB_NPM_EXIT, mirroring the real CLI (which exits 1 whenever any advisory is
# reported, clean JSON or not).
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/npm" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_NPM_JSON:-}" ] && cat "$STUB_NPM_JSON"
exit "${STUB_NPM_EXIT:-0}"
STUB
chmod +x "$stub_bin/npm"

# A `date` that rolls an out-of-range day over into the next month instead of
# rejecting it — busybox and pre-9 coreutils behave this way, and the runner image
# is not part of this gate's contract. GNU coreutils 9 rejects `2026-09-31`
# outright, so on this box alone the script's round-trip check would look like dead
# code; under a lenient `date` it is the only thing standing between a typo'd
# review-by and an exception that never expires. Prepended via $path_prefix.
lenient_bin="$tmp/lenient-date"
mkdir -p "$lenient_bin"
ln -sf "$(command -v date)" "$lenient_bin/date.real"
cat >"$lenient_bin/date" <<'STUB'
#!/usr/bin/env bash
real="$(dirname "$0")/date.real"
if [ "${1:-}" = -u ] && [ "${2:-}" = -d ] && [[ "${3:-}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] \
   && ! "$real" -u -d "$3" +%F >/dev/null 2>&1; then
  exec "$real" -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-01 + $((10#${BASH_REMATCH[3]} - 1)) days" "$4"
fi
exec "$real" "$@"
STUB
chmod +x "$lenient_bin/date"

# report <severity:ghsa>... -> path to a synthetic `npm audit --json` report.
# Severity counts in .metadata are derived so the fixture stays self-consistent
# with what npm would actually emit.
report() {
  local out; out="$(mktemp "$tmp/report.XXXXXX.json")"
  local advisories='[]' spec sev ghsa
  for spec in "$@"; do
    sev="${spec%%:*}"; ghsa="${spec#*:}"
    advisories="$(jq -c --arg sev "$sev" --arg ghsa "$ghsa" \
      '. + [{source: 1, name: "pkg", severity: $sev, title: ($ghsa + " title"),
             url: ("https://github.com/advisories/" + $ghsa), range: "<=1.0.0"}]' \
      <<<"$advisories")"
  done
  jq --argjson advisories "$advisories" '
    {
      auditReportVersion: 2,
      vulnerabilities: ($advisories | map({
        key: (.url | split("/") | last),
        value: {name: "pkg", severity: .severity, isDirect: false, via: [.],
                effects: [], range: "<=1.0.0", nodes: ["node_modules/pkg"],
                fixAvailable: false}
      }) | from_entries),
      metadata: {vulnerabilities: (
        {info: 0, low: 0, moderate: 0, high: 0, critical: 0} as $zero
        | reduce $advisories[] as $a ($zero; .[$a.severity] += 1)
        | . + {total: ($advisories | length)}
      )}
    }' <<<'null' >"$out"
  printf '%s' "$out"
}

# graph <vulnerabilities-json> [metadata-overrides-json] -> path to a report whose
# `via` chains are given verbatim, so a fixture can express what `report` cannot:
# multi-hop propagation, a cycle, an empty `via`, a dangling edge, or a
# .metadata count that disagrees with the packages actually enumerated.
graph() {
  local out over; out="$(mktemp "$tmp/graph.XXXXXX.json")"
  over="${2:-}"; [ -n "$over" ] || over='{}'
  jq --argjson v "$1" --argjson over "$over" '
    {
      auditReportVersion: 2,
      vulnerabilities: ($v | to_entries | map({key: .key, value: (
        {name: .key, isDirect: false, effects: [], range: "<=1.0.0",
         nodes: ["node_modules/" + .key], fixAvailable: false} + .value)})
        | from_entries),
      metadata: {vulnerabilities: (
        ({info: 0, low: 0, moderate: 0, high: 0, critical: 0} as $zero
         | reduce ($v | to_entries[]) as $e ($zero; .[$e.value.severity] += 1)
         | . + {total: ($v | length)}) + $over)}
    }' <<<'null' >"$out"
  printf '%s' "$out"
}

# adv <ghsa> <package> <severity> -> one `via` advisory object (an advisory root).
adv() {
  printf '{"source": 1, "name": "%s", "severity": "%s", "title": "%s title", "url": "https://github.com/advisories/%s", "range": "<=1.0.0"}' \
    "$2" "$3" "$1" "$1"
}

# allowlist <entry-json>... -> path to an allowlist data file.
allowlist() {
  local out; out="$(mktemp "$tmp/allowlist.XXXXXX.json")"
  printf '%s\n' "$@" | jq -s '{allowlist: .}' >"$out"
  printf '%s' "$out"
}

entry() { # entry <ghsa> <review-by> [package] [severity]
  printf '{"ghsa": "%s", "package": "%s", "severity": "%s", "reason": "test fixture", "review-by": "%s"}' \
    "$1" "${3:-pkg}" "${4:-high}" "$2"
}

# run_case <report> <allowlist> [npm-exit] [today] -> prints exit status.
# Bounded on purpose: the `via` graph is walked recursively and npm reports do
# contain cycles, so a gate that never terminates would wedge CI exactly like one
# that fails open. A timeout surfaces as a non-zero status, never as a hung suite.
path_prefix=''
run_case() {
  timeout 20 env PATH="${path_prefix:+$path_prefix:}$stub_bin:$PATH" \
    STUB_NPM_JSON="$1" \
    STUB_NPM_EXIT="${3:-1}" \
    RELEASE_TOOLING_DIR="$tmp" \
    RELEASE_TOOLING_AUDIT_ALLOWLIST="$2" \
    RELEASE_TOOLING_AUDIT_TODAY="${4:-2026-07-25}" \
    bash "$script" >"$tmp/out" 2>&1
  printf '%s' "$?"
}

# 1. A report with no advisories at all passes.
[ "$(run_case "$(report)" "$(allowlist)" 0)" = 0 ] \
  && pass "clean audit report exits 0" \
  || fail "clean audit report did not exit 0: $(cat "$tmp/out")"

# 2. A high advisory that nobody has excused fails the gate.
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$(allowlist)")" = 1 ] \
  && pass "unlisted high advisory exits 1" \
  || fail "unlisted high advisory did not exit 1: $(cat "$tmp/out")"

# 3. Critical is above the threshold too, not only high.
[ "$(run_case "$(report critical:GHSA-dddd-eeee-ffff)" "$(allowlist)")" = 1 ] \
  && pass "unlisted critical advisory exits 1" \
  || fail "unlisted critical advisory did not exit 1: $(cat "$tmp/out")"

# 4. The gate's threshold is high, so a moderate is reported but not blocking —
# preserving the behaviour of the `--audit-level=high` invocation it replaced.
[ "$(run_case "$(report moderate:GHSA-1111-2222-3333)" "$(allowlist)")" = 0 ] \
  && pass "moderate advisory stays below the high threshold" \
  || fail "moderate advisory did not exit 0: $(cat "$tmp/out")"

# 5. A high advisory named in the allowlist, still inside its review window, is
# excused — the whole point of the wrapper.
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 0 ] \
  && pass "allowlisted high advisory inside its review window exits 0" \
  || fail "allowlisted high advisory did not exit 0: $(cat "$tmp/out")"

# 6. An accepted risk must not silently become permanent: once today is past the
# entry's review-by, the exception expires and the gate fails again.
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-07-24)")")" = 1 ] \
  && pass "allowlist entry past its review-by exits 1" \
  || fail "stale allowlist entry did not exit 1: $(cat "$tmp/out")"

# 7. Once upstream ships a fix the exception is dead permission, so an entry that
# matches no reported advisory fails until someone deletes it.
[ "$(run_case "$(report)" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")" 0)" = 1 ] \
  && pass "allowlist entry matching no advisory exits 1" \
  || fail "unmatched allowlist entry did not exit 1: $(cat "$tmp/out")"

# 8. An unreadable audit must never read as "clean".
printf 'not json at all\n' >"$tmp/malformed.json"
[ "$(run_case "$tmp/malformed.json" "$(allowlist)" 0)" = 1 ] \
  && pass "malformed audit JSON fails closed" \
  || fail "malformed audit JSON did not exit 1: $(cat "$tmp/out")"

# 9. npm blew up (registry down, bad lockfile) and printed nothing parseable.
: >"$tmp/empty.json"
[ "$(run_case "$tmp/empty.json" "$(allowlist)" 127)" = 1 ] \
  && pass "npm exiting non-zero with no parseable JSON fails closed" \
  || fail "unparseable npm failure did not exit 1: $(cat "$tmp/out")"

# 10. Valid JSON of the wrong shape is not a clean report.
printf '{"ok": true}\n' >"$tmp/wrong-shape.json"
[ "$(run_case "$tmp/wrong-shape.json" "$(allowlist)" 0)" = 1 ] \
  && pass "well-formed JSON without an audit report shape fails closed" \
  || fail "wrong-shape JSON did not exit 1: $(cat "$tmp/out")"

# 11. npm counts a high package but no advisory object can be attributed to it:
# the report shape has moved, so the allowlist comparison is meaningless.
jq '.vulnerabilities |= map_values(.via = ["some-other-package"])' \
  "$(report high:GHSA-aaaa-bbbb-cccc)" >"$tmp/no-advisory.json"
[ "$(run_case "$tmp/no-advisory.json" "$(allowlist)")" = 1 ] \
  && pass "counted high with no extractable advisory fails closed" \
  || fail "unattributable high did not exit 1: $(cat "$tmp/out")"

# 11b. ...and the same drift is still fatal when the allowlist is non-empty: an
# excused advisory must not vouch for a package nothing can be attributed to.
jq '.vulnerabilities += {"evil": {name: "evil", severity: "critical",
      isDirect: false, via: ["not-listed-anywhere"], effects: [],
      range: "<=1.0.0", nodes: ["node_modules/evil"], fixAvailable: false}}
    | .metadata.vulnerabilities.critical = 1
    | .metadata.vulnerabilities.total += 1' \
  "$(report high:GHSA-aaaa-bbbb-cccc)" >"$tmp/excused-plus-unattributable.json"
[ "$(run_case "$tmp/excused-plus-unattributable.json" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "unattributable critical alongside an excused advisory fails closed" \
  || fail "unattributable critical was excused by an unrelated entry: $(cat "$tmp/out")"

# evil_package <report> <via-json> -> report with an extra unexcused critical.
evil_package() {
  jq --argjson via "$2" '.vulnerabilities += {"evil": {name: "evil",
        severity: "critical", isDirect: false, via: $via, effects: [],
        range: "<=1.0.0", nodes: ["node_modules/evil"], fixAvailable: false}}
      | .metadata.vulnerabilities.critical += 1
      | .metadata.vulnerabilities.total += 1' "$1"
}

# 11c. A `via` advisory with no severity at all is a report we cannot grade, and
# a live exception elsewhere must not make it look benign.
evil_package "$(report high:GHSA-aaaa-bbbb-cccc)" \
  '[{"source": 2, "name": "evil", "title": "no severity",
     "url": "https://github.com/advisories/GHSA-dddd-eeee-ffff", "range": "<=1.0.0"}]' \
  >"$tmp/no-severity.json"
[ "$(run_case "$tmp/no-severity.json" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "advisory without a severity fails closed" \
  || fail "severity-less advisory did not exit 1: $(cat "$tmp/out")"

# 11d. Severity spelling is normalised, so case is not a way past the threshold.
evil_package "$(report high:GHSA-aaaa-bbbb-cccc)" \
  '[{"source": 2, "name": "evil", "severity": "Critical", "title": "shouty",
     "url": "https://github.com/advisories/GHSA-dddd-eeee-ffff", "range": "<=1.0.0"}]' \
  >"$tmp/uppercase.json"
jq '.vulnerabilities.evil.severity = "CRITICAL"' "$tmp/uppercase.json" >"$tmp/uppercase2.json"
[ "$(run_case "$tmp/uppercase2.json" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "uppercase severity still blocks" \
  || fail "uppercase severity was not treated as critical: $(cat "$tmp/out")"

# 11e. npm's counts are the coverage check's other half, so they must be numbers:
# a string count made the comparison error out and skip the guard.
jq '.metadata.vulnerabilities.high = "2"' "$(report high:GHSA-aaaa-bbbb-cccc)" \
  >"$tmp/string-count.json"
[ "$(run_case "$tmp/string-count.json" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "non-numeric severity counts fail closed" \
  || fail "non-numeric severity count did not exit 1: $(cat "$tmp/out")"

# 11f. npm propagates an advisory outward through `via` strings, so a graded
# package is usually several hops from the advisory root that explains it (the
# real report reaches brace-expansion via semantic-release -> @semantic-release/npm
# -> npm). Resolution has to walk the whole chain, not just the first hop.
chain='{
  "top": {"severity": "high", "via": ["mid"]},
  "mid": {"severity": "moderate", "via": ["pkg"]},
  "pkg": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"']}
}'
[ "$(run_case "$(graph "$chain")" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 0 ] \
  && pass "a high package two hops from its advisory root resolves and is excused" \
  || fail "multi-hop via chain did not resolve to the excused advisory: $(cat "$tmp/out")"

# 11g. ...and an unexcused advisory at the far end of that same chain still blocks,
# so walking the chain cannot become a way of losing the advisory.
[ "$(run_case "$(graph "$chain")" "$(allowlist)")" = 1 ] \
  && grep -q 'GHSA-aaaa-bbbb-cccc' "$tmp/out" \
  && pass "an unexcused advisory two hops out still blocks and is named" \
  || fail "multi-hop unexcused advisory did not exit 1 naming the GHSA: $(cat "$tmp/out")"

# 11h. npm reports contain genuine `via` cycles (semantic-release <->
# @semantic-release/npm in our own lockfile). Resolution must terminate on one:
# a gate that spins forever wedges CI exactly like one that fails open.
cyclic='{
  "top": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"', "mid"]},
  "mid": {"severity": "moderate", "via": ["top"]}
}'
[ "$(run_case "$(graph "$cyclic")" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 0 ] \
  && pass "a cyclic via chain terminates and resolves to the excused advisory" \
  || fail "cyclic via chain did not terminate with exit 0: $(cat "$tmp/out")"

# 11i. A package reached mid-chain that carries no `via` at all explains nothing,
# so the chain is incomplete — an excused advisory earlier in it must not vouch
# for the rest.
empty_via='{
  "top": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"', "mid"]},
  "mid": {"severity": "moderate", "via": []}
}'
[ "$(run_case "$(graph "$empty_via")" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && grep -q 'no advisory could be attributed' "$tmp/out" \
  && pass "an empty via mid-chain is unattributable, not excused" \
  || fail "empty via mid-chain did not fail closed: $(cat "$tmp/out")"

# 11j. The regression this wrapper was rewritten to close: one graded package whose
# `via` carries the excused advisory AND an edge to a package npm never reported.
# The dangling edge is exactly the unexplained part, so the excused advisory must
# not carry the package on its own.
dangling='{
  "pkg": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"', "ghost"]}
}'
[ "$(run_case "$(graph "$dangling")" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && grep -q 'no advisory could be attributed' "$tmp/out" \
  && pass "an excused advisory plus a dangling edge is still unattributable" \
  || fail "dangling via edge was excused by the advisory beside it: $(cat "$tmp/out")"

# 11k. The coverage guard on its own: every package the report enumerates is
# excused, and only npm's own count says there is another one. Nothing else in the
# script can fail this report, so the guard is the single thing under test.
inflated='{
  "pkg": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"']}
}'
[ "$(run_case "$(graph "$inflated" '{"high": 2}')" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && grep -q 'could be enumerated' "$tmp/out" \
  && pass "npm counting more blocking packages than were enumerated fails closed" \
  || fail "inflated high count did not trip the coverage guard: $(cat "$tmp/out")"

# 11l. A count that is a number but not a whole one is the same hole as a string
# count one type over: `[ 2.5 -gt 1 ]` is an error, not a comparison, and with
# `set -e` off an erroring `[` skips the `&& die` beside it and the gate sails on.
[ "$(run_case "$(graph "$inflated" '{"high": 2.5}')" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "a fractional severity count fails closed" \
  || fail "fractional severity count did not exit 1: $(cat "$tmp/out")"

# 11m. ...and a whole number is not enough either: jq renders a large one in
# exponent notation (`1e+100`), which `[` also refuses as an integer. The guard
# must not depend on a count being formatted the way `test(1)` likes.
[ "$(run_case "$(graph "$inflated" '{"high": 1e100}')" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "a severity count jq renders in exponent notation fails closed" \
  || fail "exponent-notation severity count did not exit 1: $(cat "$tmp/out")"

# 11n. A fractional count *below* the number of packages enumerated satisfies the
# coverage comparison, so nothing downstream would notice it. npm counts whole
# packages; a report that says 0.5 of one is a report we cannot read.
[ "$(run_case "$(graph "$inflated" '{"high": 0.5}')" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && grep -q 'could not parse' "$tmp/out" \
  && pass "a fractional count the coverage guard would accept still fails closed" \
  || fail "fractional count below the enumerated total did not exit 1: $(cat "$tmp/out")"

# 11o. ...and a negative count would pass the coverage comparison against *any*
# number of enumerated packages, disabling the guard outright.
[ "$(run_case "$(graph "$inflated" '{"high": -1}')" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && grep -q 'could not parse' "$tmp/out" \
  && pass "a negative severity count fails closed" \
  || fail "negative severity count did not exit 1: $(cat "$tmp/out")"

# 12. The allowlist is the reviewable artefact; without it there is no gate.
[ "$(run_case "$(report)" "$tmp/does-not-exist.json" 0)" = 1 ] \
  && pass "absent allowlist file fails closed" \
  || fail "absent allowlist did not exit 1: $(cat "$tmp/out")"

# 12b. A truncated write leaves an empty file, which `jq -e` waves through because
# it produced no output — the schema guard has to reject it by name.
: >"$tmp/zero-byte.json"
[ "$(run_case "$(report)" "$tmp/zero-byte.json" 0)" = 1 ] \
  && grep -q 'allowlist is malformed' "$tmp/out" \
  && pass "zero-byte allowlist is rejected by the schema guard" \
  || fail "zero-byte allowlist was not rejected cleanly: $(cat "$tmp/out")"

# 13. An entry without a review-by would be a permanent exception by omission.
undated="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "reason": "no expiry"}')"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$undated")" = 1 ] \
  && pass "allowlist entry without a review-by fails closed" \
  || fail "undated allowlist entry did not exit 1: $(cat "$tmp/out")"

# 14. ...and an unreviewable date is no expiry either.
baddate="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "reason": "x", "review-by": "soon"}')"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$baddate")" = 1 ] \
  && pass "allowlist entry with a non-ISO review-by fails closed" \
  || fail "non-ISO review-by did not exit 1: $(cat "$tmp/out")"

# 14b. A month typo is ISO-shaped but not a date, and would never expire.
notadate="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "package": "pkg", "severity": "high", "reason": "x", "review-by": "2026-13-45"}')"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$notadate")" = 1 ] \
  && pass "allowlist entry with an impossible calendar date fails closed" \
  || fail "impossible review-by did not exit 1: $(cat "$tmp/out")"

# 14d. `2026-13-45` is refused by GNU `date`, so it never reaches the round-trip.
# Where `date` is lenient (busybox, older coreutils) an impossible day is accepted
# and silently rolled over — `2026-09-31` becomes October 1 — and only comparing
# the normalised value against the original catches it. The date is deliberately
# inside the live window (not expired, not past the horizon) so no later guard can
# stand in for the round-trip, and the message is asserted for the same reason.
rollover="$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-09-31)")"
path_prefix="$lenient_bin"
rollover_status="$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$rollover")"
path_prefix=''
[ "$rollover_status" = 1 ] \
  && grep -q 'review-by is not a real calendar date: 2026-09-31' "$tmp/out" \
  && pass "a review-by a lenient date(1) rolls over is still not a real date" \
  || fail "rolled-over review-by was not rejected as a non-date: $(cat "$tmp/out")"

# 14c. A far-future review-by is an expiry that never fires, so the window is
# capped: an accepted risk has to come back for re-assessment.
forever="$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 9999-12-31)")"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$forever")" = 1 ] \
  && pass "allowlist entry beyond the review horizon fails closed" \
  || fail "far-future review-by did not exit 1: $(cat "$tmp/out")"

# 15. An exception with no stated reason is not a reviewed decision.
noreason="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "reason": "", "review-by": "2026-08-25"}')"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$noreason")" = 1 ] \
  && pass "allowlist entry without a reason fails closed" \
  || fail "reasonless allowlist entry did not exit 1: $(cat "$tmp/out")"

# 15b. An entry that matches nothing in the report is dead permission and is
# rejected before any package is graded — so this case never reaches the excusing
# comparison, and the message is what distinguishes the two.
mismatched="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "package": "other-pkg", "severity": "low", "reason": "wrong package and severity", "review-by": "2026-08-25"}')"
[ "$(run_case "$(report critical:GHSA-aaaa-bbbb-cccc)" "$mismatched")" = 1 ] \
  && grep -q 'match no reported advisory' "$tmp/out" \
  && pass "allowlist entry naming another package/severity is dead permission" \
  || fail "mismatched allowlist entry was not rejected as dead permission: $(cat "$tmp/out")"

# 15c. ...and where the entry *does* match something, it still excuses only that
# one advisory-in-package-at-severity: the same GHSA id reported against another
# package, at another grade, is a separate risk nobody assessed. Both advisories
# are reported here, so the dead-permission guard above is satisfied and the
# narrowing itself is what has to block.
same_ghsa='{
  "other-pkg": {"severity": "low", "via": ['"$(adv GHSA-aaaa-bbbb-cccc other-pkg low)"']},
  "pkg": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"']}
}'
[ "$(run_case "$(graph "$same_ghsa")" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25 other-pkg low)")")" = 1 ] \
  && grep -q 'unexcused high/critical' "$tmp/out" \
  && pass "an entry excuses its GHSA in its own package only, not the same id elsewhere" \
  || fail "an entry excused the same GHSA in a package it does not name: $(cat "$tmp/out")"

# 15d. The severity a reviewer accepts is the one they assessed. npm grades the
# PACKAGE — the unit `--audit-level=high` gated on — and that grade can sit above
# the advisory's own, so an entry accepting a `high` advisory must not carry a
# package npm calls `critical`: that is a risk nobody signed off on.
undergraded='{
  "pkg": {"severity": "critical", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg high)"']}
}'
[ "$(run_case "$(graph "$undergraded")" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25 pkg high)")")" = 1 ] \
  && grep -q 'critical' "$tmp/out" \
  && pass "an entry accepting a high advisory does not excuse a critical package" \
  || fail "a high exception excused a package npm graded critical: $(cat "$tmp/out")"

# 15e. ...but npm grades a package at the MAX over its chain, so a chain that also
# reaches a lower-graded advisory is the ordinary multi-CVE shape, not an anomaly.
# Since an entry's severity is pinned to the grade npm reports for its advisory,
# demanding that *every* advisory reach the package's grade would make this package
# unexcusable by construction — the unbypassable wedge #146 exists to remove. One
# excused advisory at the package's own grade is what has to carry it.
mixed_grade='{
  "pkg": {"severity": "critical", "via": ['"$(adv GHSA-aaaa-bbbb-cccc pkg critical)"', '"$(adv GHSA-9999-8888-7777 pkg moderate)"']}
}'
[ "$(run_case "$(graph "$mixed_grade")" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25 pkg critical)" \
                   "$(entry GHSA-9999-8888-7777 2026-08-25 pkg moderate)")")" = 0 ] \
  && pass "a critical package excused at its own grade is not blocked by a lesser advisory beside it" \
  || fail "a mixed-grade chain was unexcusable despite covering the package's grade: $(cat "$tmp/out")"

# 15f. ...and the same holds when the lower-graded advisory is a hop away rather
# than a sibling, which is how the real report reaches its graded packages.
mixed_chain='{
  "top": {"severity": "high", "via": ['"$(adv GHSA-aaaa-bbbb-cccc top high)"', "mid"]},
  "mid": {"severity": "moderate", "via": ['"$(adv GHSA-9999-8888-7777 mid moderate)"']}
}'
[ "$(run_case "$(graph "$mixed_chain")" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25 top high)" \
                   "$(entry GHSA-9999-8888-7777 2026-08-25 mid moderate)")")" = 0 ] \
  && pass "a high package excused at its own grade is not blocked by a moderate advisory a hop away" \
  || fail "a multi-hop mixed-grade chain was unexcusable despite covering the package's grade: $(cat "$tmp/out")"

# 16. Boundary: the exception is still good on its review-by date itself.
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-07-25)")")" = 0 ] \
  && pass "allowlist entry on its review-by date is still valid" \
  || fail "review-by boundary did not exit 0: $(cat "$tmp/out")"

# 17. One excused high does not excuse its neighbour.
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc high:GHSA-9999-8888-7777)" \
      "$(allowlist "$(entry GHSA-aaaa-bbbb-cccc 2026-08-25)")")" = 1 ] \
  && pass "a second, unlisted high still fails alongside an excused one" \
  || fail "unlisted high alongside an excused one did not exit 1: $(cat "$tmp/out")"

# 18. The blocking advisory is named, so a reviewer sees what to assess.
run_case "$(report high:GHSA-9999-8888-7777)" "$(allowlist)" >/dev/null
grep -q 'GHSA-9999-8888-7777' "$tmp/out" \
  && pass "failure output names the blocking GHSA" \
  || fail "failure output does not name the blocking GHSA: $(cat "$tmp/out")"

# 18b. A runner without npm produces no report at all, which is not "clean".
nonpm_bin="$tmp/nonpm"
mkdir -p "$nonpm_bin"
for tool in jq date dirname; do ln -sf "$(command -v "$tool")" "$nonpm_bin/$tool"; done
env -i PATH="$nonpm_bin" \
  RELEASE_TOOLING_DIR="$tmp" \
  RELEASE_TOOLING_AUDIT_ALLOWLIST="$(allowlist)" \
  RELEASE_TOOLING_AUDIT_TODAY=2026-07-25 \
  "$(command -v bash)" "$script" >"$tmp/out" 2>&1
[ "$?" = 1 ] \
  && pass "npm missing from PATH fails closed" \
  || fail "absent npm did not exit 1: $(cat "$tmp/out")"

# 19. Wiring: the gate step must call the wrapper, and the bare `npm audit`
# invocation must be gone — otherwise the allowlist is decorative and the org is
# back to the all-or-nothing check that #146 wedged.
actions_ci="$repo_root/.github/workflows/actions-ci.yml"
{ grep -qF 'run: bash scripts/release-tooling-audit.sh' "$actions_ci" \
  && grep -qF 'run: bash scripts/release-tooling-audit.test.sh' "$actions_ci" \
  && ! grep -qE 'npm audit .*--audit-level' "$actions_ci"; } \
  && pass "actions-ci runs the wrapper and this test, not a bare npm audit" \
  || fail "actions-ci does not wire the release-tooling audit wrapper and its test"

# 20. The shipped allowlist is the artefact a reviewer diffs: it must satisfy the
# same schema the gate enforces, and stay small enough to actually be read.
shipped="$repo_root/.github/release-tooling/audit-allowlist.json"
jq -e '
  (.allowlist | type == "array") and (.allowlist | length <= 5) and
  (.allowlist | all(
    (.ghsa | test("^GHSA(-[0-9a-z]+){3}$")) and (.reason | length > 40) and
    (.["review-by"] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))
' "$shipped" >/dev/null 2>&1 \
  && pass "shipped allowlist is well-formed and each entry carries a real reason" \
  || fail "shipped allowlist is malformed, oversized, or has an entry without a reason: $shipped"

[ "$fails" -eq 0 ] && exit 0
printf '\n%d check(s) failed\n' "$fails"
exit 1

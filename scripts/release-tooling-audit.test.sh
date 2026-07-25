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

# allowlist <entry-json>... -> path to an allowlist data file.
allowlist() {
  local out; out="$(mktemp "$tmp/allowlist.XXXXXX.json")"
  printf '%s\n' "$@" | jq -s '{allowlist: .}' >"$out"
  printf '%s' "$out"
}

entry() { # entry <ghsa> <review-by>
  printf '{"ghsa": "%s", "package": "pkg", "severity": "high", "reason": "test fixture", "review-by": "%s"}' "$1" "$2"
}

# run_case <report> <allowlist> [npm-exit] [today] -> prints exit status
run_case() {
  env PATH="$stub_bin:$PATH" \
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

# 15b. `package` and `severity` are documented fields, so they must narrow the
# exception: an entry naming another package or a lower severity excuses nothing.
mismatched="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "package": "other-pkg", "severity": "low", "reason": "wrong package and severity", "review-by": "2026-08-25"}')"
[ "$(run_case "$(report critical:GHSA-aaaa-bbbb-cccc)" "$mismatched")" = 1 ] \
  && pass "allowlist entry naming another package/severity excuses nothing" \
  || fail "mismatched allowlist entry excused a critical: $(cat "$tmp/out")"

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

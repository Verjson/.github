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

# 12. The allowlist is the reviewable artefact; without it there is no gate.
[ "$(run_case "$(report)" "$tmp/does-not-exist.json" 0)" = 1 ] \
  && pass "absent allowlist file fails closed" \
  || fail "absent allowlist did not exit 1: $(cat "$tmp/out")"

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

# 15. An exception with no stated reason is not a reviewed decision.
noreason="$(allowlist '{"ghsa": "GHSA-aaaa-bbbb-cccc", "reason": "", "review-by": "2026-08-25"}')"
[ "$(run_case "$(report high:GHSA-aaaa-bbbb-cccc)" "$noreason")" = 1 ] \
  && pass "allowlist entry without a reason fails closed" \
  || fail "reasonless allowlist entry did not exit 1: $(cat "$tmp/out")"

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

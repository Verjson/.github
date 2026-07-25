#!/usr/bin/env bash
# Fail-closed supply-chain gate for the release tooling (Verjson/.github#146, #89).
#
# Replaces a bare `npm audit --audit-level=high`, which is all-or-nothing: one
# unfixable transitive advisory (GHSA-mh99-v99m-4gvg, bundled inside npm's own
# CLI) wedged every PR in the org, leaving only "weaken the gate wholesale" or
# "delete the check". This wrapper adds the missing middle: a reviewed, dated,
# per-advisory exception in `audit-allowlist.json`.
#
# Blocks on any high/critical advisory that is not explicitly excused, and — so
# an accepted risk can't quietly become permanent — also blocks when an
# exception outlives its `review-by` or stops matching anything. Every path that
# cannot fully interpret the report exits non-zero: an unreadable audit must
# never read as "clean".
#
# Env (tests only): RELEASE_TOOLING_DIR, RELEASE_TOOLING_AUDIT_ALLOWLIST,
# RELEASE_TOOLING_AUDIT_TODAY.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tooling_dir="${RELEASE_TOOLING_DIR:-$repo_root/.github/release-tooling}"
allowlist_file="${RELEASE_TOOLING_AUDIT_ALLOWLIST:-$repo_root/.github/release-tooling/audit-allowlist.json}"
today="${RELEASE_TOOLING_AUDIT_TODAY:-$(date -u +%F)}"

die() { printf 'release-tooling-audit: %s\n' "$1" >&2; exit 1; }

[ -f "$allowlist_file" ] || die "allowlist file not found: $allowlist_file"
jq -e '
  (.allowlist | type == "array") and
  (.allowlist | all(
    (.ghsa | type == "string") and (.ghsa | test("^GHSA(-[0-9a-z]+){3}$")) and
    (.reason | type == "string") and (.reason | length > 0) and
    (.["review-by"] | type == "string") and (.["review-by"] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  ))
' "$allowlist_file" >/dev/null 2>&1 \
  || die "allowlist is malformed — every entry needs a GHSA id, a reason and a YYYY-MM-DD review-by: $allowlist_file"

# npm audit exits non-zero whenever it reports anything at all, so the exit code
# alone decides nothing; the JSON does. A report we cannot parse is fatal.
report="$(cd "$tooling_dir" && npm audit --json --package-lock-only --omit=dev 2>/dev/null)"
npm_status=$?
[ -n "$report" ] || die "npm audit produced no output (npm exit $npm_status) — failing closed"
jq -e '
  (.auditReportVersion >= 2) and
  (.vulnerabilities | type == "object") and
  (.metadata.vulnerabilities | type == "object")
' <<<"$report" >/dev/null 2>&1 \
  || die "could not parse an npm audit report (npm exit $npm_status) — failing closed"

# The advisory objects inside `via` are the roots; string entries are just
# propagation edges to another reported package.
advisories="$(jq -c '
  [.vulnerabilities[]?.via[]? | select(type == "object")
   | {ghsa: (.url // "" | split("/") | last), severity: (.severity // "unknown"), title: (.title // "")}]
  | unique
' <<<"$report")" || die "could not extract advisories from the audit report — failing closed"

# Guard the extraction itself: npm counted high/critical packages but we found no
# advisory to attribute them to, so the report shape has moved under us.
counted_blocking="$(jq -r '.metadata.vulnerabilities | (.high // 0) + (.critical // 0)' <<<"$report")"
extracted_blocking="$(jq -r '[.[] | select(.severity == "high" or .severity == "critical")] | length' <<<"$advisories")"
{ [ "$counted_blocking" -gt 0 ] && [ "$extracted_blocking" -eq 0 ]; } \
  && die "npm reports $counted_blocking high/critical package(s) but no advisory could be extracted — failing closed"

expired="$(jq -r --arg today "$today" '[.allowlist[] | select(.["review-by"] < $today) | .ghsa] | join(" ")' "$allowlist_file")"
[ -n "$expired" ] \
  && die "allowlist entr(ies) are past their review-by ($today) — re-assess or drop them: $expired"

unmatched="$(jq -r --slurpfile allow "$allowlist_file" '
  map(.ghsa) as $reported
  | [$allow[0].allowlist[] | .ghsa as $ghsa | select(($reported | index($ghsa)) == null) | $ghsa]
  | join(" ")
' <<<"$advisories")" || die "could not compare the allowlist against the audit report — failing closed"
[ -n "$unmatched" ] \
  && die "allowlist entr(ies) match no reported advisory — delete the dead exception: $unmatched"

blocking="$(jq -r --slurpfile allow "$allowlist_file" '
  ($allow[0].allowlist | map(.ghsa)) as $excused
  | [.[] | . as $a
     | select($a.severity == "high" or $a.severity == "critical")
     | select(($excused | index($a.ghsa)) == null)
     | "  \($a.severity)\t\($a.ghsa)\t\($a.title)"]
  | join("\n")
' <<<"$advisories")" || die "could not evaluate the audit report against the allowlist — failing closed"
if [ -n "$blocking" ]; then
  printf 'release-tooling-audit: unexcused high/critical advisor(ies):\n%s\n' "$blocking" >&2
  exit 1
fi

excused="$(jq -r --arg today "$today" '
  [.allowlist[] | "  \(.ghsa) — accepted until \(.["review-by"]): \(.reason)"] | join("\n")
' "$allowlist_file")"
printf 'release-tooling-audit: no unexcused high/critical advisories.\n'
[ -n "$excused" ] && printf 'Accepted risks (expire on review-by):\n%s\n' "$excused"
exit 0

#!/usr/bin/env bash
# Fail-closed supply-chain gate for the release tooling (Verjson/.github#146, #89).
#
# Replaces a bare `npm audit --audit-level=high`, which is all-or-nothing: one
# unfixable transitive advisory (GHSA-mh99-v99m-4gvg, bundled inside npm's own
# CLI) wedged every PR in the org, leaving only "weaken the gate wholesale" or
# "delete the check". This wrapper adds the missing middle: a reviewed, dated,
# per-advisory exception in `audit-allowlist.json`.
#
# The verdict is per PACKAGE, exactly like the `--audit-level=high` it replaces:
# every package npm grades high/critical must resolve, through its `via` chain,
# entirely to advisories the allowlist excuses by id, package and severity — and at
# a severity that covers npm's grade for the package, so a `high` exception cannot
# carry a `critical` package. A package nothing can be attributed to blocks. And —
# so an accepted risk can't quietly become permanent — an exception that outlives
# its `review-by`, is dated beyond the review horizon, or stops matching anything
# blocks too. Every path
# that cannot fully interpret the report exits non-zero: an unreadable audit must
# never read as "clean".
#
# Test seams, honoured unconditionally (there is no production/test distinction at
# runtime): RELEASE_TOOLING_DIR, RELEASE_TOOLING_AUDIT_ALLOWLIST and
# RELEASE_TOOLING_AUDIT_TODAY. Setting TODAY moves the clock and so disables every
# expiry check — the workflow step must invoke this script with none of them set.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tooling_dir="${RELEASE_TOOLING_DIR:-$repo_root/.github/release-tooling}"
allowlist_file="${RELEASE_TOOLING_AUDIT_ALLOWLIST:-$repo_root/.github/release-tooling/audit-allowlist.json}"
today="${RELEASE_TOOLING_AUDIT_TODAY:-$(date -u +%F)}"

die() { printf 'release-tooling-audit: %s\n' "$1" >&2; exit 1; }

[ -f "$allowlist_file" ] || die "allowlist file not found: $allowlist_file"
# `jq -e` exits 0 when it produces no output at all, so an empty or whitespace-only
# file would sail through the schema guard: require the literal `true`.
schema_ok="$(jq -r '
  def level: type == "string" and (ascii_downcase | . == "info" or . == "low"
    or . == "moderate" or . == "high" or . == "critical");
  (type == "object") and (has("allowlist")) and
  (.allowlist | type == "array") and
  (.allowlist | all(
    (.ghsa | type == "string") and (.ghsa | test("^GHSA(-[0-9a-z]+){3}$")) and
    (.package | type == "string") and (.package | length > 0) and
    (.severity | level) and
    (.reason | type == "string") and (.reason | length > 0) and
    (.["review-by"] | type == "string") and (.["review-by"] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  ))
' "$allowlist_file" 2>/dev/null)"
[ "$schema_ok" = true ] \
  || die "allowlist is malformed — every entry needs a GHSA id, the package and severity it excuses, a reason and a YYYY-MM-DD review-by: $allowlist_file"

# An ISO *shape* is not a date: `2026-13-45` never arrives, so it would be a
# permanent exception. Round-trip every review-by through `date` and require it to
# come back unchanged, and cap the window so it cannot be widened to infinity.
horizon_days=90
date -u -d "$today" +%F >/dev/null 2>&1 || die "today is not a valid date: $today"
horizon="$(date -u -d "$today + $horizon_days days" +%F)" \
  || die "could not compute the review-by horizon from $today — failing closed"
review_dates="$(jq -r '.allowlist[] | .["review-by"]' "$allowlist_file")" \
  || die "could not read the allowlist review-by dates — failing closed"
while IFS= read -r review_by; do
  [ -n "$review_by" ] || continue
  normalised="$(date -u -d "$review_by" +%F 2>/dev/null)" \
    || die "review-by is not a real calendar date: $review_by"
  [ "$normalised" = "$review_by" ] \
    || die "review-by is not a real calendar date: $review_by"
  [[ "$review_by" > "$horizon" ]] \
    && die "review-by $review_by is more than $horizon_days days out (past $horizon) — keep the window short enough to actually be re-assessed"
done <<<"$review_dates"

# npm audit exits non-zero whenever it reports anything at all, so the exit code
# alone decides nothing; the JSON does. A report we cannot parse is fatal.
report="$(cd "$tooling_dir" && npm audit --json --package-lock-only --omit=dev 2>/dev/null)"
npm_status=$?
[ -n "$report" ] || die "npm audit produced no output (npm exit $npm_status) — failing closed"
shape_ok="$(jq -r '
  def level: type == "string" and (ascii_downcase | . == "info" or . == "low"
    or . == "moderate" or . == "high" or . == "critical");
  (.auditReportVersion >= 2) and
  (.vulnerabilities | type == "object") and
  (.vulnerabilities | all(
    (.severity | level) and (.via | type == "array") and
    (.via | all(type == "string" or (type == "object" and (.severity | level)))))) and
  (.metadata.vulnerabilities | type == "object") and
  (.metadata.vulnerabilities | [.info, .low, .moderate, .high, .critical]
   | all(type == "number" and . == floor and . >= 0))
' <<<"$report" 2>/dev/null)"
[ "$shape_ok" = true ] \
  || die "could not parse an npm audit report, or it carries an unknown severity (npm exit $npm_status) — failing closed"

# npm's own per-package severity is what `--audit-level` gated on, so the verdict
# is per PACKAGE, not per advisory: every high/critical package must resolve —
# through its `via` chain, where objects are advisory roots and strings are
# propagation edges to another reported package — entirely to excused advisories.
# A package whose chain cannot be resolved is unattributable, and blocks.
analysis="$(jq -c '
  def advisory($o): {
    ghsa: ($o.url // "" | split("/") | last),
    package: ($o.name // ""),
    severity: ($o.severity | ascii_downcase)
  };
  def resolve($v; $frontier; $seen; $found; $ok):
    if ($frontier | length) == 0 then {advisories: ($found | unique), ok: $ok}
    else ($frontier[0]) as $n | ($frontier[1:]) as $rest
      | if ($seen | index($n)) != null then resolve($v; $rest; $seen; $found; $ok)
        elif ($v | has($n)) == false then resolve($v; $rest; $seen + [$n]; $found; false)
        else ($v[$n].via) as $via
          | ($via | map(select(type == "object") | advisory(.))) as $roots
          | resolve($v; $rest + ($via | map(select(type == "string"))); $seen + [$n];
                    $found + $roots;
                    ($ok and ($via | length) > 0
                     and ($roots | all(.ghsa | test("^GHSA(-[0-9a-z]+){3}$")))))
        end
    end;
  .vulnerabilities as $v
  | {
      reported: ([$v[]?.via[]? | select(type == "object") | advisory(.)] | unique),
      blocking: [$v | to_entries[]
        | select(.value.severity | ascii_downcase | . == "high" or . == "critical")
        | {package: .key, severity: (.value.severity | ascii_downcase)}
          + resolve($v; [.key]; []; []; true)]
    }
' <<<"$report")" || die "could not analyse the audit report — failing closed"

# Coverage guard: every high/critical package npm counted must be one we found and
# resolved, otherwise the report shape has moved under us.
counted_blocking="$(jq -r '.metadata.vulnerabilities | .high + .critical' <<<"$report")" \
  || die "could not read npm's severity counts — failing closed"
found_blocking="$(jq -r '.blocking | length' <<<"$analysis")" \
  || die "could not count the blocking packages — failing closed"
# The comparison is done in jq, not by `[ -gt ]`: `set -e` is off, so a `[` whose
# operands it refuses (a fractional count, or a whole one jq renders as `1e+100`)
# exits non-zero *without* running the `&& die` beside it — the guard would fail
# open on exactly the malformed report it exists to catch. Every remaining `[` in
# this script compares strings, which cannot error.
coverage_ok="$(jq -rn --argjson counted "$counted_blocking" --argjson found "$found_blocking" \
  '$counted <= $found')" \
  || die "could not compare npm's counts against the packages enumerated — failing closed"
[ "$coverage_ok" = true ] \
  || die "npm reports $counted_blocking high/critical package(s) but only $found_blocking could be enumerated — failing closed"

expired="$(jq -r --arg today "$today" '
  [.allowlist[] | select(.["review-by"] < $today) | .ghsa] | join(" ")
' "$allowlist_file")" || die "could not check the allowlist for expiry — failing closed"
[ -n "$expired" ] \
  && die "allowlist entr(ies) are past their review-by ($today) — re-assess or drop them: $expired"

# An exception is scoped to one advisory in one package at one severity, so all
# three have to still match something in the report; anything else is either dead
# permission or an entry that never applied.
unmatched="$(jq -r --slurpfile allow "$allowlist_file" '
  .reported as $reported
  | [$allow[0].allowlist[]
     | {ghsa, package, severity: (.severity | ascii_downcase)} as $entry
     | select(($reported | index($entry)) == null)
     | "\($entry.ghsa) (\($entry.package)/\($entry.severity))"]
  | join(" ")
' <<<"$analysis")" || die "could not compare the allowlist against the audit report — failing closed"
[ -n "$unmatched" ] \
  && die "allowlist entr(ies) match no reported advisory — delete the dead exception: $unmatched"

# npm grades a package at the MAX over its chain, so reaching a lower-graded
# advisory alongside the top one is the ordinary multi-CVE/multi-hop shape. The
# grade check is therefore "SOME excused advisory reaches the package's grade",
# not "every one does": an entry's severity is pinned to the grade npm reports
# for its advisory, so the stricter reading would leave such a package
# unexcusable by any allowlist at all.
blocking="$(jq -r --slurpfile allow "$allowlist_file" '
  def rank: {info: 0, low: 1, moderate: 2, high: 3, critical: 4}[.];
  ($allow[0].allowlist
   | map({ghsa, package, severity: (.severity | ascii_downcase)})) as $excused
  | [.blocking[] | . as $p
     | ($p.advisories | map(. as $a | select(($excused | index($a)) == null))) as $unexcused
     | ($p.advisories | map(select((.severity | rank) >= ($p.severity | rank)))) as $covering
     | if ($p.ok | not) or ($p.advisories | length) == 0 then
         "  \($p.severity)\t\($p.package)\tno advisory could be attributed to this package"
       elif ($unexcused | length) > 0 then
         "  \($p.severity)\t\($p.package)\t\($unexcused | map(.ghsa) | join(", "))"
       elif ($covering | length) == 0 then
         "  \($p.severity)\t\($p.package)\tno excused advisory reaches this package’s \($p.severity) grade (highest accepted: \($p.advisories | map(.severity) | unique | join("/")))"
       else empty end]
  | join("\n")
' <<<"$analysis")" || die "could not evaluate the audit report against the allowlist — failing closed"
if [ -n "$blocking" ]; then
  printf 'release-tooling-audit: unexcused high/critical package(s):\n%s\n' "$blocking" >&2
  exit 1
fi

excused="$(jq -r '
  [.allowlist[] | "  \(.ghsa) in \(.package) — accepted until \(.["review-by"]): \(.reason)"]
  | join("\n")
' "$allowlist_file")" || die "could not summarise the accepted risks — failing closed"
printf 'release-tooling-audit: no unexcused high/critical advisories.\n'
[ -n "$excused" ] && printf 'Accepted risks (expire on review-by):\n%s\n' "$excused"
exit 0

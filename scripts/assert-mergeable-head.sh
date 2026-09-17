#!/usr/bin/env bash
# Replacement for the organization's pre-merge assertion
#
#   gh pr view N --json statusCheckRollup --jq \
#     '[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'
#
# which ADR 0178 made ambiguous in the one direction that matters. That form
# answers a single question — "is anything red?" — so a deferred head, a head
# missing a required check entirely, and a head with a genuinely failing
# advisory check all collapse into one bare `false`. The predictable field fix
# for an opaque `false` is to widen the accepted-conclusion list, which is
# precisely how `Verjson/verjson-cli#251`'s unexercised-head class returns.
#
# This script answers three separable questions and names which one failed, so
# that relaxing any of them is a deliberate, reviewable act rather than an
# allowlist edit made under time pressure:
#
#   Gate A  every REQUIRED context for the base ref exists on the head, has
#           completed, and passed. An absent required check fails closed
#           (ADR 0024) instead of being silently satisfied by its own absence.
#   Gate B  positive evidence that verification actually executed: the head
#           carries no ADR 0178 `deferred-ci` check that ran, and no ADR 0156
#           deferral annotation. This is the gate a deferred Renovate head
#           fails, and it says so in those words.
#   Gate C  no other check on the head is pending or non-passing.
#
# Prints "true" and exits 0 only when all three hold. Every other outcome is a
# fault: a `::error::` naming the gate, and a distinct exit code — never a bare
# "false", and never a zero exit on an unanswered question.
#
#   2  usage error
#   3  Gate A failed (required contexts absent, pending, or not passing)
#   4  Gate B failed (the head was deferred; nothing on it was verified)
#   5  Gate C failed (some other check is pending or non-passing)
#   1  the assertion could not be evaluated (API failure, unresolvable state)
set -uo pipefail

usage() { echo "usage: $0 <owner/repo> <pr-number>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
repo="$1"
pr="$2"
[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ "$pr" =~ ^[0-9]+$ ]] || usage

deferred_pattern="${DEFERRED_CHECK_ANNOTATION_PATTERN:-^CI deferred$}"
# ADR 0178 fixes the job id; a caller renames its own job, not the reusable's,
# so the deferral surfaces as `<caller-job> / deferred-ci` or bare `deferred-ci`.
deferred_job_pattern="${DEFERRED_CHECK_JOB_PATTERN:-(^|/ )deferred-ci$}"

fault() { echo "::error::$2" >&2; exit "$1"; }

pr_json="$(gh pr view "$pr" --repo "$repo" --json headRefOid,baseRefName,statusCheckRollup)" \
  || fault 1 "failed to fetch pull request metadata for $repo#$pr"

head_sha="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fault 1 "could not resolve a head SHA for $repo#$pr"
base_ref="$(jq -r '.baseRefName // ""' <<<"$pr_json")"
[ -n "$base_ref" ] \
  || fault 1 "could not resolve a base ref for $repo#$pr"

# ---------------------------------------------------------------- Gate A ----
# The required set is read from the ruleset that actually governs the base ref.
# It is never inferred from what the head happens to have reported: that is the
# same error as trusting an adopter-supplied header, and it lets a head satisfy
# the gate by reporting nothing at all.
rules_json="$(gh api "repos/$repo/rules/branches/$base_ref")" \
  || fault 1 "failed to read branch rules for $repo@$base_ref; cannot establish the required-check set"

required="$(jq -r '
  [ .[]?
    | select(.type == "required_status_checks")
    | .parameters.required_status_checks[]?
    | .context
    | select(. != null and . != "")
  ] | unique | .[]
' <<<"$rules_json")" \
  || fault 1 "failed to parse branch rules for $repo@$base_ref"

[ -n "$required" ] \
  || fault 3 "$repo@$base_ref declares no required status checks, so a green rollup proves nothing about it; this assertion cannot gate an ungoverned ref"

# Index the rollup under both shapes a required context can take: the check
# run's own name, and `<workflow> / <job>` as branch protection reports it for
# a reusable caller.
rollup="$(jq -c '
  [ .statusCheckRollup[]?
    | { names: ([ (.name // .context), ((.workflowName // "") + " / " + (.name // "")) ] | map(select(. != null and . != "" and . != " / "))),
        status: (.status // "COMPLETED" | ascii_upcase),
        conclusion: ((.conclusion // .state // "") | ascii_upcase) }
  ]
' <<<"$pr_json")" \
  || fault 1 "failed to parse the status check rollup for $repo#$pr"

passing_conclusions='["SUCCESS","NEUTRAL","SKIPPED"]'

gate_a="$(jq -r --argjson pass "$passing_conclusions" --arg ctxs "$required" '
  ($ctxs | split("\n") | map(select(. != ""))) as $required
  | [ $required[]
      | . as $ctx
      | ( [ $rollup[] | select(.names | index($ctx)) ] ) as $matches
      | if ($matches | length) == 0 then "absent: \($ctx)"
        elif ($matches | any(.status != "COMPLETED")) then "pending: \($ctx)"
        elif ($matches | any(.conclusion as $c | ($pass | index($c)) == null)) then "not passing: \($ctx) (\($matches | map(.conclusion) | join(",")))"
        else empty end
    ] | join("; ")
' --argjson rollup "$rollup" <<<'null')" \
  || fault 1 "failed to evaluate required contexts for $repo#$pr"

[ -z "$gate_a" ] \
  || fault 3 "Gate A: $repo#$pr head $head_sha does not satisfy every required context of $base_ref — $gate_a"

# ---------------------------------------------------------------- Gate B ----
# A rollup entry proves a check reported; it does not prove the check did work.
# ADR 0178's `deferred-ci` runs only on a defer, so its having RUN at all — any
# conclusion other than SKIPPED, including a conclusion this gate would
# otherwise call passing — is direct evidence the head was never exercised.
deferred_checks="$(jq -r --arg pat "$deferred_job_pattern" '
  [ $rollup[]
    | select(.names | any(test($pat)))
    | select(.conclusion != "SKIPPED")
    | "\(.names[0])=\(if .status != "COMPLETED" then .status else .conclusion end)"
  ] | join(", ")
' --argjson rollup "$rollup" <<<'null')" \
  || fault 1 "failed to evaluate deferral checks for $repo#$pr"

[ -z "$deferred_checks" ] \
  || fault 4 "Gate B: $repo#$pr head $head_sha was DEFERRED, not verified — $deferred_checks. No test, lint, type check, or repository-local contract guard ran on this head (ADR 0178, Verjson/verjson-cli#251). Wait for the release-age gate to clear and Renovate to rebase, or force a real run with workflow_dispatch. Do not merge, and do not relax this gate to make the head look green."

# ADR 0156's annotation still covers consumers of the `ci-eligibility` composite
# action, which build their own jobs and never emit a `deferred-ci` check.
check_run_ids="$(gh api --paginate "repos/$repo/commits/$head_sha/check-runs?per_page=100" \
  | jq -s '[.[].check_runs[] | select(.conclusion != null) | .id] | unique | .[]')" \
  || fault 1 "failed to fetch check runs for $repo@$head_sha"

deferred_annotations=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  titles="$(gh api --paginate "repos/$repo/check-runs/$id/annotations?per_page=100" \
    | jq -s -r --arg pat "$deferred_pattern" '
        [.[][] | select(.title != null and (.title | test($pat))) | .title] | join(", ")
      ')" \
    || fault 1 "failed to fetch annotations for check-run $id on $repo"
  [ -n "$titles" ] && deferred_annotations="${deferred_annotations:+$deferred_annotations; }check-run $id: $titles"
done <<<"$check_run_ids"

[ -z "$deferred_annotations" ] \
  || fault 4 "Gate B: $repo#$pr head $head_sha carries a deferral annotation, so a check reported without executing its work — $deferred_annotations (ADR 0156)"

# ---------------------------------------------------------------- Gate C ----
gate_c="$(jq -r --argjson pass "$passing_conclusions" '
  [ $rollup[]
    | select(.conclusion as $c | (.status != "COMPLETED") or (($pass | index($c)) == null))
    | "\(.names[0])=\(if .status != "COMPLETED" then .status else .conclusion end)"
  ] | unique | join(", ")
' --argjson rollup "$rollup" <<<'null')" \
  || fault 1 "failed to evaluate non-required checks for $repo#$pr"

[ -z "$gate_c" ] \
  || fault 5 "Gate C: $repo#$pr head $head_sha has pending or non-passing checks outside the required set — $gate_c"

echo true

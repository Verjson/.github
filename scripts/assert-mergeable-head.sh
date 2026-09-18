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
#   Gate A  every REQUIRED context for the base ref exists on the head, was
#           produced by the app the ruleset binds it to, has completed, and
#           passed. An absent required check fails closed (ADR 0024) instead of
#           being silently satisfied by its own absence.
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
# PERMISSIONS. Gate A reads `repos/{owner}/{repo}/rules/branches/{base}`, and it
# is the ONLY source of the required set. A caller whose token cannot read that
# endpoint therefore cannot evaluate Gate A at all, and this script refuses
# rather than falling back to the head's own reported checks. The read needs
# ordinary repository read access and nothing more:
#
#   fine-grained token   Repository permissions > Metadata (read)
#   classic OAuth token  `repo` for a private repository; no scope for a public one
#   GitHub Actions       permissions.contents: read
#
# `administration` is NOT required, and an organization-level ruleset is
# returned through this repository endpoint without organization read --
# verified against `repos/Verjson/.github/rules/branches/main`, which returns
# its org-sourced `required_status_checks` rule to a wholly unauthenticated
# caller. An authorization refusal (401/403, or the 404 GitHub substitutes when
# it masks an unauthorized read of a private repository) exits 1 with a message
# naming the token as the cause and listing the access above; it is never a
# silent pass and never an undifferentiated API error.
#
#   2  usage error
#   3  Gate A failed (required contexts absent, misattributed, pending, or not passing)
#   4  Gate B failed (the head was deferred; nothing on it was verified)
#   5  Gate C failed (some other check is pending or non-passing)
#   1  the assertion could not be evaluated (API failure, unresolvable state)
#
# There is deliberately NO environment override for any gate's matching rule.
# An earlier draft exposed the deferral patterns as tunable variables, which
# made disabling Gate B a one-variable edit — cheaper than the allowlist
# widening this script exists to prevent, and invisible in the output. A gate
# whose strictness is configurable at the call site is not a gate.
# `-e` is deliberately absent: the advisory-check loop below ends on a test that
# is legitimately false, which would abort under `-e`. Correctness therefore
# rests on every command substitution carrying its own `|| fault` — do not add
# an unguarded `$(...)` here.
set -uo pipefail

usage() { echo "usage: $0 <owner/repo> <pr-number>" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
repo="$1"
pr="$2"
[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ "$pr" =~ ^[0-9]+$ ]] || usage

# ADR 0178 fixes the job id. A caller renames its own job, not the reusable's,
# so the deferral surfaces as `deferred-ci` or `<caller-job> / deferred-ci`, and
# a matrix value is appended in parentheses. A commit-status context uses the
# conventional `prefix/deferred-ci` form with no space, so both separators are
# accepted on each side. Names are matched as reported, never trimmed: Gate A's
# exact-name comparison must stay whitespace-sensitive, so a padded name reports
# `absent` and fails closed rather than silently satisfying a required context.
readonly DEFERRED_JOB_PATTERN='(^|[/ ])deferred-ci([ (/]|$)'
readonly DEFERRED_ANNOTATION_PATTERN='^CI deferred$'
readonly PASSING='["SUCCESS","NEUTRAL","SKIPPED"]'

fault() { echo "::error::$2" >&2; exit "$1"; }

# Both inventory endpoints state how many entries exist. Reconciling that claim
# against what the page walk actually collected is what turns a truncated walk
# into a fault instead of a short green inventory. Defaulting the CLAIM to the
# OBSERVATION would make the check vacuous exactly when it matters — an empty
# body, or a shape without `total_count`, would reconcile 0 against 0 and let the
# gate reason over nothing at all. So the attestation is required, not optional.
reconcile_pages() {
  jq -se --arg field "$2" '
    [.[]] as $pages
    | if ($pages | length) == 0 then
        error("\($field): the response carried no page at all")
      elif ($pages[0].total_count | type) != "number" then
        error("\($field): the response states no total_count, so the walk is unattested")
      else . end
    | ($pages | map(.[$field]? // []) | add // [] | length) as $got
    | $pages[0].total_count as $claimed
    | if $got == $claimed then true
      else error("\($field): the page walk returned \($got) of \($claimed)") end' \
    >/dev/null <<<"$1"
}

pr_json="$(gh pr view "$pr" --repo "$repo" --json headRefOid,baseRefName </dev/null)" \
  || fault 1 "failed to fetch pull request metadata for $repo#$pr"

head_sha="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fault 1 "could not resolve a head SHA for $repo#$pr"
base_ref="$(jq -r '.baseRefName // ""' <<<"$pr_json")"
[ -n "$base_ref" ] \
  || fault 1 "could not resolve a base ref for $repo#$pr"
# A ref name is a path segment sequence; percent-encode anything else so a
# `release/1.x` base ref addresses the ruleset endpoint rather than a 404.
base_ref_path="$(jq -rn --arg r "$base_ref" '$r | @uri' | sed 's|%2F|/|g')" \
  || fault 1 "could not encode the base ref for $repo#$pr"

# The head's checks are read from REST rather than from `gh pr view`'s
# `statusCheckRollup`, because the rollup projection carries no app identity and
# Gate A has to know WHO produced a required check, not merely that something
# with the right display name reported.
# `total_count` is reconciled against what was actually collected: a truncated
# pagination would otherwise shrink the inventory silently, and a gate that
# reasons over a short inventory is the failure this script exists to prevent.
check_runs_raw="$(gh api --paginate "repos/$repo/commits/$head_sha/check-runs?per_page=100" </dev/null)" \
  || fault 1 "failed to fetch check runs for $repo@$head_sha"
reconcile_pages "$check_runs_raw" check_runs \
  || fault 1 "the check-run inventory for $repo@$head_sha is incomplete or unattested; it cannot be reasoned over"
check_runs="$(jq -s '[ .[].check_runs[]? | {
      name: (.name // ""),
      status: ((.status // "completed") | ascii_upcase),
      conclusion: ((.conclusion // "") | ascii_upcase),
      app_id: (.app.id // null),
      id: .id,
      kind: "check_run" } ]' <<<"$check_runs_raw")" \
  || fault 1 "failed to normalize check runs for $repo@$head_sha"

# Legacy commit statuses are a separate endpoint and carry no app id at all.
# `--paginate` matters here as much as on check runs: this endpoint returns 30
# statuses per page by default, and a `failure` stranded on page 2 would be
# invisible to Gate C, which is the gate that exists to see it.
statuses_raw="$(gh api --paginate "repos/$repo/commits/$head_sha/status?per_page=100" </dev/null)" \
  || fault 1 "failed to fetch commit statuses for $repo@$head_sha"
reconcile_pages "$statuses_raw" statuses \
  || fault 1 "the commit-status inventory for $repo@$head_sha is incomplete or unattested; it cannot be reasoned over"
statuses="$(jq -s '[ .[] | .statuses[]? | {
      name: (.context // ""),
      status: (if ((.state // "") | ascii_upcase) == "PENDING" then "IN_PROGRESS" else "COMPLETED" end),
      conclusion: (((.state // "") | ascii_upcase) | if . == "PENDING" then "" elif . == "ERROR" then "FAILURE" else . end),
      app_id: null,
      id: null,
      kind: "status" } ]' <<<"$statuses_raw")" \
  || fault 1 "failed to normalize commit statuses for $repo@$head_sha"

checks="$(jq -n --argjson a "$check_runs" --argjson b "$statuses" '$a + $b')" \
  || fault 1 "failed to assemble the check inventory for $repo@$head_sha"

# ---------------------------------------------------------------- Gate A ----
# The required set is read from the ruleset that actually governs the pull
# request's BASE REF. It is never inferred from the head: that is the same
# error as trusting an adopter-supplied header, and it lets a head satisfy the
# gate by reporting nothing at all.
# `gh api` exits 1 for an authorization refusal and for a transient 5xx alike,
# so the exit code alone cannot tell an operator whether to retry or to fix a
# token. Gate A is not merely failed when this read is refused -- it is
# UNEVALUABLE, which is the fail-open shape this script exists to prevent, so
# the status is read off stderr and the permission cause is named outright.
rules_err="$(mktemp)" \
  || fault 1 "could not allocate a scratch file to capture the ruleset read's diagnostics"
trap 'rm -f "$rules_err"' EXIT
rules_json="$(gh api --paginate "repos/$repo/rules/branches/$base_ref_path" </dev/null 2>"$rules_err" | jq -s 'add // []')" || {
  cat "$rules_err" >&2
  # Match the LAST status in the stream: `--paginate` may emit several lines,
  # and the refusal that ended the walk is the one that explains it.
  rules_status="$(sed -n 's/.*(HTTP \([0-9]\{3\}\)).*/\1/p' "$rules_err" | tail -1)"
  case "$rules_status" in
    401 | 403 | 404)
      fault 1 "Gate A cannot read the ruleset at repos/$repo/rules/branches/$base_ref (HTTP $rules_status): the token presented cannot read it. Gate A's required set comes only from this endpoint and is never inferred from the head, so this refusal is fatal rather than degraded. Grant the caller read access to $repo -- fine-grained token: Repository permissions > Metadata (read); classic OAuth token: 'repo' for a private repository, no scope at all for a public one; inside Actions: permissions.contents: read. The 'administration' scope is NOT required, and an organization-level ruleset is returned through this repository endpoint without organization read. Note that GitHub masks an unauthorized read of a private repository as 404, so do not conclude from a 404 that the repository or base ref is missing until the token has been checked." ;;
  esac
  fault 1 "failed to read branch rules for $repo@$base_ref; cannot establish the required-check set"
}

required="$(jq -c '
  [ .[]?
    | select(type == "object" and .type == "required_status_checks")
    | .parameters.required_status_checks[]?
    | select(type == "object" and (.context // "") != "")
    | { context: .context, integration_id: (.integration_id // null) }
  ] | unique
' <<<"$rules_json")" \
  || fault 1 "failed to parse branch rules for $repo@$base_ref"

required_count="$(jq 'length' <<<"$required")" \
  || fault 1 "failed to count the required contexts of $repo@$base_ref"
[ "$required_count" -gt 0 ] \
  || fault 3 "$repo@$base_ref declares no required status checks, so a green rollup proves nothing about it; this assertion cannot gate an ungoverned ref"

# A required context is matched by EXACT name — the form branch protection
# itself uses — and, when the ruleset binds it to an app, by that app's id.
# An earlier draft also matched a synthesized "<workflowName> / <name>", which
# let any workflow satisfy a required context by naming a job after it.
gate_a="$(jq -r --argjson pass "$PASSING" --argjson required "$required" '
  [ $required[]
    | . as $req
    | ([ $checks[] | select(.name == $req.context) ]) as $named
    | if ($named | length) == 0 then "absent: \($req.context)"
      else
        ( if $req.integration_id == null then $named
          else [ $named[] | select(.app_id == $req.integration_id) ] end ) as $owned
        | if ($owned | length) == 0 then
            "wrong producer: \($req.context) (ruleset binds app \($req.integration_id); head has \($named | map(.app_id | tostring) | join(",")))"
          elif ($owned | any(.status != "COMPLETED")) then "pending: \($req.context)"
          elif ($owned | any(.conclusion as $c | ($pass | index($c)) == null)) then
            "not passing: \($req.context) (\($owned | map(.conclusion) | join(",")))"
          else empty end
      end
  ] | join("; ")
' --argjson checks "$checks" <<<'null')" \
  || fault 1 "failed to evaluate required contexts for $repo#$pr"

[ -z "$gate_a" ] \
  || fault 3 "Gate A: $repo#$pr head $head_sha does not satisfy every required context of $base_ref — $gate_a"

# A ruleset may declare a required context without binding it to an app. Gate A
# then has nothing to check provenance against and matches on display name
# alone, which is the ADR 0024 class it otherwise closes. That degradation is
# real and must be visible rather than silent; it is a warning and not a fault
# because refusing every unbound context would refuse rulesets that are
# currently correct, including this organization's own hub.
unbound="$(jq -r --argjson required "$required" -n '
  [ $required[] | select(.integration_id == null) | .context ] | join(", ")')" \
  || fault 1 "failed to evaluate unbound required contexts for $repo#$pr"
[ -z "$unbound" ] \
  || echo "::warning::Gate A matched these required contexts on display name alone, because $base_ref binds them to no app: $unbound" >&2

# ---------------------------------------------------------------- Gate B ----
# A check entry proves a check REPORTED; it does not prove the check did work.
# ADR 0178's `deferred-ci` runs only on a defer, so its having RUN at all — any
# conclusion other than SKIPPED, including one this gate would otherwise call
# passing — is direct evidence the head was never exercised.
deferred_checks="$(jq -r --arg pat "$DEFERRED_JOB_PATTERN" '
  [ $checks[]
    | select(.name | test($pat; "i"))
    | select(.conclusion != "SKIPPED")
    | "\(.name)=\(if .status != "COMPLETED" then .status else .conclusion end)"
  ] | unique | join(", ")
' --argjson checks "$checks" <<<'null')" \
  || fault 1 "failed to evaluate deferral checks for $repo#$pr"

[ -z "$deferred_checks" ] \
  || fault 4 "Gate B: $repo#$pr head $head_sha was DEFERRED, not verified — $deferred_checks. No test, lint, type check, or repository-local contract guard ran on this head (ADR 0178, Verjson/verjson-cli#251). Wait for the release-age gate to clear and Renovate to rebase, or force a real run with workflow_dispatch. Do not merge, and do not relax this gate to make the head look green."

# ADR 0156's annotation still covers consumers of the `ci-eligibility` composite
# action, which build their own jobs and never emit a `deferred-ci` check.
check_run_ids="$(jq -r '[ $checks[] | select(.kind == "check_run" and .conclusion != "") | .id ] | unique | .[]' \
  --argjson checks "$checks" <<<'null')" \
  || fault 1 "failed to enumerate check runs for $repo@$head_sha"

deferred_annotations=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  titles="$(gh api --paginate "repos/$repo/check-runs/$id/annotations?per_page=100" </dev/null \
    | jq -s -r --arg pat "$DEFERRED_ANNOTATION_PATTERN" '
        [.[][]? | select(.title != null and (.title | test($pat))) | .title] | join(", ")
      ')" \
    || fault 1 "failed to fetch annotations for check-run $id on $repo"
  [ -n "$titles" ] && deferred_annotations="${deferred_annotations:+$deferred_annotations; }check-run $id: $titles"
done <<<"$check_run_ids"

[ -z "$deferred_annotations" ] \
  || fault 4 "Gate B: $repo#$pr head $head_sha carries a deferral annotation, so a check reported without executing its work — $deferred_annotations (ADR 0156)"

# ---------------------------------------------------------------- Gate C ----
gate_c="$(jq -r --argjson pass "$PASSING" '
  [ $checks[]
    | select(.conclusion as $c | (.status != "COMPLETED") or (($pass | index($c)) == null))
    | "\(.name)=\(if .status != "COMPLETED" then .status else .conclusion end)"
  ] | unique | join(", ")
' --argjson checks "$checks" <<<'null')" \
  || fault 1 "failed to evaluate non-required checks for $repo#$pr"

[ -z "$gate_c" ] \
  || fault 5 "Gate C: $repo#$pr head $head_sha has pending or non-passing checks outside the required set — $gate_c"

echo true

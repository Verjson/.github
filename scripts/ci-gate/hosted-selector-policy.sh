#!/usr/bin/env bash
# Verjson/.github#814 — refuse metered GitHub-hosted runner selectors and
# unbounded hosted jobs in a directory of Actions workflow files.
#
#   hosted-selector-policy.sh --visibility public|private <workflow-dir> [sanctioned-workflow ...]
#
# Exit 0 is "scanned and clean", 1 is "policy violation", 2 is "undetermined".
# The three are distinct because a sweep that scans nothing must not look like a
# sweep that found nothing — the same convention scripts/runner-selector-health.sh
# uses, and the reason that script exits 2 rather than 0 when it cannot decide.
set -uo pipefail

undetermined() {
  printf 'UNDETERMINED: %s\n' "$1" >&2
  exit 2
}

visibility=""
workflow_dir=""
sanctioned=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --visibility)
      [ "$#" -ge 2 ] || undetermined "--visibility requires a value"
      visibility="$2"
      shift 2
      ;;
    --visibility=*)
      visibility="${1#--visibility=}"
      shift
      ;;
    -*)
      undetermined "unrecognized option: $1"
      ;;
    *)
      if [ -z "$workflow_dir" ]; then
        workflow_dir="$1"
      else
        sanctioned+=("$1")
      fi
      shift
      ;;
  esac
done

case "$visibility" in
  public|private) ;;
  *) undetermined "--visibility must be exactly 'public' or 'private' (got '$visibility')" ;;
esac
[ -n "$workflow_dir" ] || undetermined "no workflow directory given"
[ -d "$workflow_dir" ] || undetermined "not a directory: $workflow_dir"

# Both suffixes. GitHub runs `.yaml` and `.yml` identically, and a sweep that
# globs `*.yml` alone is evaded by renaming the file — the #401 defect, which
# regrew across every assertion in runner-routing-policy.test.sh before it was
# fixed there. It is not repeated here.
shopt -s nullglob
workflow_files=("$workflow_dir"/*.yml "$workflow_dir"/*.yaml)
shopt -u nullglob

# R5's sanctioned desktop-release path, as an EXPLICIT constant rather than an
# implicit absence. In `Verjson/.github` the set is empty and that is the whole
# rule: no workflow here may name an OS lane variable at all. `.github`
# deliberately does not grow a cross-platform release workflow — ADR 0060
# retired `node-release.yml`, and the canonical path is a dispatched
# `changelog-release.yml` that builds nothing.
#
# Trailing arguments append to this set, which is how #815 points the same
# script at a consumer checkout whose desktop-release workflow is legitimately
# sanctioned. That is a parameter and not a hole in the guarantee: R1 and R2
# take no exception from it, and the OS lane variables are repository-scoped, so
# a repository that sanctions a filename it does not own still resolves them to
# empty. R5 is a legibility rule — one grep that answers "who can spend hosted
# minutes" — layered on top of that containment, not the containment itself.
# It is deliberately NOT `github.repository == 'Verjson/AiB'`: hardcoding the
# consumer's name here would make a second desktop repository a pull request in
# this repository instead of a variable edit, which is the property ADR 0041
# exists to preserve.
SANCTIONED_OS_LANE_WORKFLOWS=()
sanctioned=("${SANCTIONED_OS_LANE_WORKFLOWS[@]}" "${sanctioned[@]}")

violations=0
report() {
  printf '%s:%s: %s\n' "$1" "$2" "$3" >&2
  violations=$((violations + 1))
}

# Emit one tab-separated record per job:
#   file, job, runs-on line, runs-on value, timeout line, timeout value, strategy text
#
# Parsed structurally rather than grepped, because every interesting evasion is
# a shape rather than a word: a flow sequence (`runs-on: [macos-15]`), a block
# sequence, a quoted scalar, a trailing comment, a matrix indirection. Indent
# levels are DERIVED (the first key inside `jobs:` fixes the job indent; the
# first key inside a job fixes the property indent) rather than assumed to be
# two spaces, so a consumer checkout with a different but self-consistent style
# is still parsed — #815 points this same script at ~89 of them.
#
# Deliberately NOT matched: a `runs-on:` nested deeper than the job property
# level. Those are step-script heredocs — actionlint.yml carries four, as lint
# fixtures — and they place no job.
parse_jobs() {
  awk -v file="$1" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # A comment after a plain scalar needs whitespace before the `#` in YAML, so
    # this strips the comment without eating a `#` inside a value.
    function strip_comment(s) { sub(/[[:space:]]+#.*$/, "", s); return s }
    function flush() {
      if (job != "")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
          file, job, runs_on_line, runs_on, timeout_line, timeout, strategy
      job = ""
    }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/ { next }
    {
      pad = line
      sub(/[^ ].*$/, "", pad)
      indent = length(pad)
    }
    line ~ /^jobs:[[:space:]]*(#.*)?$/ { flush(); in_jobs = 1; job_indent = -1; next }
    !in_jobs { next }
    indent == 0 { flush(); in_jobs = 0; next }
    job_indent < 0 { job_indent = indent }
    indent == job_indent {
      flush()
      job = strip_comment(trim(line))
      sub(/:[[:space:]]*$/, "", job)
      runs_on = ""; runs_on_line = 0; timeout = ""; timeout_line = 0
      strategy = ""; prop_indent = -1; collect = ""
      next
    }
    job == "" { next }
    prop_indent < 0 { prop_indent = indent }
    indent == prop_indent && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+:/ {
      key = trim(line)
      sub(/:.*$/, "", key)
      value = line
      sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, "", value)
      value = trim(strip_comment(value))
      collect = ""
      if (key == "runs-on") { runs_on = value; runs_on_line = NR; collect = "runs-on" }
      else if (key == "timeout-minutes") { timeout = value; timeout_line = NR }
      else if (key == "strategy") { strategy = value; collect = "strategy" }
      next
    }
    indent > prop_indent && collect == "runs-on" { runs_on = runs_on " " trim(strip_comment(line)); next }
    indent > prop_indent && collect == "strategy" { strategy = strategy " " trim(strip_comment(line)); next }
    indent == prop_indent { collect = "" }
    END { flush() }
  ' "$1"
}

# R1 (Tier A) — the metered SKU families, refused outright.
#
# No allowlist, no parameter, no environment override, and deliberately NOT
# keyed on repository visibility. Visibility is a mutable organization-settings
# fact, and encoding it in workflow YAML is exactly the "stale by construction"
# defect ADR 0033 diagnosed and ADR 0040 watched regrow four times (#175, #182,
# #192, #203). A public repository flipped private turns a free `macos-latest`
# job into a 10x metered one with no commit, no review, and no signal — so the
# refusal cannot depend on what the repository happens to be today.
#
# Preceded by a non-word character so `VERJSON_LANE_TRUSTED_MACOS` — the lane
# variable NAME, governed by R5 — is not read as a macOS selector.
metered_family='(^|[^A-Za-z0-9_])(macos|windows)-[A-Za-z0-9]'

# The OS-scoped lanes of ADR 0103. They are repository variables on the one
# desktop repository, never organization variables, so a workflow anywhere else
# resolves them to empty; the rules below make that inability explicit rather
# than leaving it as a puzzling misconfiguration.
os_lane='vars\.VERJSON_LANE_TRUSTED_(MACOS|WINDOWS)'

# R3's ceiling. Not a presence check: `timeout-minutes: 360` satisfies "has a
# timeout" while being exactly the runaway the requirement exists to prevent —
# six hours at macOS's 10x multiplier is up to 3,600 billable minutes from one
# hung step. The lanes are configured at 45; 60 is the reviewed ceiling, so a
# leg that grows past it is a decision rather than a drift.
HOSTED_TIMEOUT_CEILING=60

is_sanctioned() {
  local candidate
  for candidate in ${sanctioned+"${sanctioned[@]}"}; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# R5 — file-wide, not `runs-on`-only. A rule that read only the selector would
# be walked around by staging the value into `env:` or a job output first, and
# the point of R5 is that ONE grep answers "which workflows can spend hosted
# minutes". A reference in a comment counts too: a commented-out selector is a
# copy-paste away from a live one, and that is exactly how this defect class
# regrew four times (#175, #182, #192, #203).
for workflow_file in "${workflow_files[@]}"; do
  is_sanctioned "$(basename "$workflow_file")" && continue
  while IFS=: read -r line_number _; do
    [ -n "$line_number" ] || continue
    report "$workflow_file" "$line_number" \
      "R5 off-path reference to an OS lane variable — only the sanctioned desktop-release path may name VERJSON_LANE_TRUSTED_MACOS or VERJSON_LANE_TRUSTED_WINDOWS"
  done < <(grep -nE 'VERJSON_LANE_TRUSTED_(MACOS|WINDOWS)' "$workflow_file" || true)
done

while IFS=$'\t' read -r file job runs_on_line runs_on timeout_line timeout strategy; do
  [ -n "${runs_on:-}" ] || continue
  # A matrix indirection places the job from `strategy.matrix`, so the selector
  # to judge is there rather than in `runs-on:` itself.
  selector="$runs_on"
  case "$runs_on" in *matrix.*) selector="$runs_on $strategy" ;; esac

  if grep -qiE "$metered_family" <<<"$selector"; then
    report "$file" "$runs_on_line" \
      "R1 metered hosted runner family in job '$job' runs-on: $runs_on"
  fi

  # R2 (Tier A) — a rolling image inside a metered family. R1 already refuses
  # the selector, so this message is the point: the two rules answer different
  # questions. R1 asks whether the org may spend here at all; R2 asks whether a
  # signed installer's build environment can change without a commit. Keeping
  # them distinct stops `macos-latest` -> `windows-latest` reading as a fix.
  if grep -qiE '(^|[^A-Za-z0-9_])(macos|windows)-latest' <<<"$selector"; then
    report "$file" "$runs_on_line" \
      "R2 rolling -latest image in job '$job' runs-on: $runs_on"
  fi

  # Tier B — literal Linux hosted selectors, keyed on repository visibility.
  #
  # Hosted minutes are FREE for a public repository (measured 2026-08-01; ADR
  # 0047 corrected ADR 0033's "unfunded" premise), so `ubuntu-latest` in a
  # public repository spends nothing and is not the runaway this check exists
  # to stop. On a private repository the same line rides the spending limit the
  # organization is raising for #810, so it is refused.
  #
  # A public repository still should not hardcode a hosted selector, and the
  # remedy is not this check: the organization already has a sanctioned path
  # for public work to reach hosted capacity — `VERJSON_RUNNER_FASTLANE`, a
  # VARIABLE (ADR 0047/0048, carved out at runner-routing-policy.test.sh:~62).
  # Because it is a variable, a capacity or provider move stays an org-variable
  # edit rather than a pull request in ~89 repositories, which is the property
  # ADR 0041 exists to preserve. A hardcoded `ubuntu-latest` reaches the same
  # runner while giving that property up. Enforcing that for public
  # repositories is #816; this comment is here so the deferral is a recorded
  # decision rather than an oversight, and `.github` itself is held to the
  # stricter standard by its own ADR 0089 inventory regardless.
  if [ "$visibility" = private ] \
    && grep -qiE '(^|[^A-Za-z0-9_])ubuntu-[A-Za-z0-9]' <<<"$selector"; then
    report "$file" "$runs_on_line" \
      "TierB literal Linux hosted selector on a private repository in job '$job' — use vars.VERJSON_RUNNER_FASTLANE or a lane variable: $runs_on"
  fi

  if ! grep -qE "$os_lane" <<<"$runs_on"; then
    # R4, the ordinary half. A non-OS lane chain must have a terminal landing —
    # `VERJSON_LANE_FALLBACK`, or the portable `'["ubuntu-24.04"]'` tail that
    # ADR 0040 put there for an organization with no lane variables at all. A
    # chain that stops at its own lane variable leaves an org that set only the
    # fallback with an EMPTY `runs-on`, and GitHub does not fail an unplaceable
    # job — it queues it forever with no check-run diagnostic (#401).
    #
    # Stated as "has a terminal landing" rather than "names FALLBACK" so that
    # node-ci.yml's ADR 0086 secretless acquisition job — deliberately
    # `VERJSON_LANE_UNTRUSTED || '["ubuntu-24.04"]'`, never the trusted
    # fallback — is covered by the rule instead of by a repository-specific
    # carve-out this script would have to carry into ~89 consumers.
    if grep -qE 'vars\.VERJSON_LANE_(TRUSTED|UNTRUSTED|PRIVILEGED)([^A-Z_]|$)' <<<"$runs_on" \
      && ! grep -qE "vars\\.VERJSON_LANE_FALLBACK|ubuntu-[A-Za-z0-9]" <<<"$runs_on"; then
      report "$file" "$runs_on_line" \
        "R4 lane selector with no terminal landing in job '$job' — it resolves to an empty runs-on when the lane variable is unset: $runs_on"
    fi
    continue
  fi

  # R4 — the OS lanes are the exception, and it runs the other way. They must
  # NOT chain to VERJSON_LANE_FALLBACK, and must not carry the portable
  # `'["ubuntu-…"]'` tail either: both spellings degrade a macOS or Windows leg
  # onto Linux, which produces a non-installable artifact behind a green check.
  # Failing closed is louder and cheaper than shipping the wrong binary.
  if grep -qE "vars\\.VERJSON_LANE_FALLBACK|ubuntu-[A-Za-z0-9]" <<<"$runs_on"; then
    report "$file" "$runs_on_line" \
      "R4 OS lane carries a fallback tail in job '$job' — an unset OS lane must fail closed, never degrade to Linux: $runs_on"
  fi

  # R3 — bounded, not merely annotated. The missing key and the over-ceiling
  # value are separate messages because they are separate mistakes: one is a
  # job nobody bounded, the other is a bound somebody chose too high.
  if [ -z "$timeout" ]; then
    report "$file" "$runs_on_line" \
      "R3 OS-lane job declares no timeout-minutes in job '$job'"
  elif ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    # An expression or a non-integer cannot be compared against the ceiling, so
    # it is refused rather than skipped: an unevaluatable bound is not a bound,
    # and skipping it is how `timeout-minutes: ${{ inputs.timeout }}` would buy
    # back the whole six-hour default through a caller-supplied value.
    report "$file" "$timeout_line" \
      "R3 OS-lane timeout-minutes is not a literal integer in job '$job': $timeout"
  elif [ "$timeout" -gt "$HOSTED_TIMEOUT_CEILING" ]; then
    report "$file" "$timeout_line" \
      "R3 OS-lane timeout-minutes $timeout exceeds the $HOSTED_TIMEOUT_CEILING ceiling in job '$job'"
  fi
done < <(
  for workflow_file in "${workflow_files[@]}"; do
    parse_jobs "$workflow_file"
  done
)

[ "$violations" -eq 0 ] || exit 1
exit 0

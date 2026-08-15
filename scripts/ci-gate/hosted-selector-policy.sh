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
# A sweep that scans nothing must not look like a sweep that found nothing. An
# empty or mis-pointed directory is the single most likely way this check ends
# up reporting green while enforcing no policy at all — a deleted workflow
# directory, a renamed path in a consumer checkout, a typo in the #815 caller.
[ "${#workflow_files[@]}" -gt 0 ] \
  || undetermined "no .yml or .yaml workflow files found under $workflow_dir"

# Job records are US-separated, so a filename carrying US or a newline would
# silently corrupt a record into a shorter one and drop the rules that read its
# later fields — a false NEGATIVE, in the direction that costs money. Such a
# name is legal on disk and creatable through a pull request, so it is refused
# as undetermined rather than parsed hopefully.
for workflow_file in "${workflow_files[@]}"; do
  case "$workflow_file" in
    *$'\037'*|*$'\n'*) undetermined "workflow filename contains a record separator or newline: $workflow_file" ;;
  esac
done

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
sanctioned=(
  ${SANCTIONED_OS_LANE_WORKFLOWS[@]+"${SANCTIONED_OS_LANE_WORKFLOWS[@]}"}
  ${sanctioned[@]+"${sanctioned[@]}"}
)

violations=0
report() {
  printf '%s:%s: %s\n' "$1" "$2" "$3" >&2
  violations=$((violations + 1))
}

# Emit one record per job, separated by US (0x1f):
#   file, job, runs-on line, runs-on value, timeout line, timeout value, strategy text
#
# US rather than TAB, and that is load-bearing rather than fussy. TAB is an IFS
# *whitespace* character, so bash `read` collapses a run of them into one
# delimiter: a job with an empty `timeout-minutes` and a non-empty `strategy`
# had the strategy text read into `timeout`, leaving the selector unscanned.
# That was a live false NEGATIVE — a matrix job with no job-level timeout — and
# the `matrix-unreferenced-key` fixture is what caught it.
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
  awk -v file="$1" -v SEP=$'\037' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # A comment after a plain scalar needs whitespace before the `#` in YAML, so
    # this strips the comment without eating a `#` inside a value.
    function strip_comment(s) { sub(/[[:space:]]+#.*$/, "", s); return s }
    function flush() {
      if (job != "")
        printf "%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
          file, SEP, job, SEP, runs_on_line, SEP, runs_on, SEP, \
          timeout_line, SEP, timeout, SEP, strategy
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
    # The optional quotes are not cosmetic: a quoted `runs-on` key is legal YAML,
    # and a key pattern accepting only the bare spelling reads that job as having
    # no selector at all — a false negative, in the direction that costs money.
    indent == prop_indent && line ~ /^[[:space:]]*["\047]?[A-Za-z0-9_.-]+["\047]?:/ {
      key = trim(line)
      sub(/:.*$/, "", key)
      gsub(/^["\047]|["\047]$/, "", key)
      value = line
      sub(/^[[:space:]]*["\047]?[A-Za-z0-9_.-]+["\047]?:[[:space:]]*/, "", value)
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

# Remove every `${{ … }}` span, leaving only the literal text around them.
#
# Scanned by index rather than by regex: `sed -E 's/\$\{\{[^}]*\}\}//g'` is
# defeated by a `}` inside an expression, and the greedy form eats everything
# between the first `${{` and the last `}}`. Both failure modes drop literal
# text, and dropping text here is a false NEGATIVE.
strip_expressions() {
  local text="$1" out="" head tail
  while [[ "$text" == *'${{'* ]]; do
    head="${text%%'${{'*}"
    tail="${text#*'${{'}"
    out+="$head "
    if [[ "$tail" == *'}}'* ]]; then
      text="${tail#*'}}'}"
    else
      # An unterminated expression: the rest of the value is inside it.
      text=""
    fi
  done
  printf '%s %s' "$out" "$text"
}

is_sanctioned() {
  local candidate
  [ "${#sanctioned[@]}" -gt 0 ] || return 1
  for candidate in "${sanctioned[@]}"; do
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

jobs_seen=0
while IFS=$'\037' read -r file job runs_on_line runs_on timeout_line timeout strategy; do
  jobs_seen=$((jobs_seen + 1))
  [ -n "${runs_on:-}" ] || continue
  # A matrix indirection places the job from `strategy.matrix`, so the selector
  # to judge is there rather than in `runs-on:` itself.
  #
  # Known imprecision, chosen deliberately: the WHOLE strategy block is judged,
  # not only the key the selector references, so a metered word in an
  # unreferenced cross-compile key is refused too. Resolving the reference
  # precisely means re-implementing YAML scoping here, and a bug in that would
  # produce a false NEGATIVE. A false positive costs an argument and is fixed by
  # renaming a key; a false negative costs money. Pinned by the
  # `matrix-unreferenced-key` fixture so it stays a decision.
  selector="$runs_on"
  case "$runs_on" in *matrix.*) selector="$runs_on $strategy" ;; esac

  # ------------------------------------------------------------------------
  # EVERY rule below judges `$selector`, never `$runs_on`. That divergence is
  # not a style preference — it produced a live false negative, in the
  # direction that costs money, and it was invisible fifty lines further down.
  #
  # The shape that evaded it is the one #810 proposes and AiB will adopt:
  #
  #     strategy: { matrix: { include: [ { lane: '${{ vars.VERJSON_LANE_TRUSTED_MACOS }}' } ] } }
  #     runs-on: ${{ fromJSON(matrix.lane) }}
  #
  # With the lane variable in the strategy block and never in `runs-on:`, the
  # OS-lane test read `$runs_on`, found nothing, and `continue`d past R3 and R4
  # entirely. R1 and R2 already folded the strategy in, so the suite looked
  # healthy while the two rules that exist specifically to BOUND hosted spend
  # were absent on the one workflow they were written for.
  #
  # `$selector` differs from `$runs_on` only when `runs-on` references
  # `matrix.`, so the folding is scoped to jobs whose placement genuinely lives
  # in the strategy block. Anything added below must read `$selector` unless it
  # is asking a question about the literal text of the `runs-on:` value itself
  # — and the one rule that does (Tier B's "is this an expression at all")
  # states that reason at its own site.
  # ------------------------------------------------------------------------

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
  # Scoped to a LITERAL selector — a value that is not an Actions expression at
  # all. Inside a `${{ … }}` chain, `'["ubuntu-24.04"]'` is ADR 0040's
  # portability tail, which appears in the generated caller of every consumer
  # and which runner-routing-policy.test.sh:~92 already strips for this exact
  # reason. Firing on it would reject ~89 private repositories for conforming to
  # the contract, and a check nobody can keep switched on enforces nothing. The
  # word in the requirement is *literal*, and this is where that word is cashed.
  # "Not an expression" is asked of the TEXT OUTSIDE every `${{ … }}` span
  # rather than of `$runs_on` wholesale. Both directions matter, and the
  # earlier `[[ "$runs_on" != *'${{'* ]]` form got each of them wrong once:
  #  * `runs-on: ${{ matrix.os }}` with `matrix: { os: [ubuntu-latest] }` is a
  #    hardcoded selector placed through an indirection. The old form saw an
  #    expression and skipped it — the same matrix blind spot as R3/R4.
  #  * `'["ubuntu-24.04"]'` inside a lane chain is ADR 0040's portability tail
  #    and must stay exempt, which is what stripping the expression preserves.
  if [ "$visibility" = private ] \
    && grep -qiE '(^|[^A-Za-z0-9_])ubuntu-[A-Za-z0-9]' \
      <<<"$(strip_expressions "$selector")"; then
    report "$file" "$runs_on_line" \
      "TierB literal Linux hosted selector on a private repository in job '$job' — use vars.VERJSON_RUNNER_FASTLANE or a lane variable: $runs_on"
  fi

  if ! grep -qE "$os_lane" <<<"$selector"; then
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
    if grep -qE 'vars\.VERJSON_LANE_(TRUSTED|UNTRUSTED|PRIVILEGED)([^A-Z_]|$)' <<<"$selector" \
      && ! grep -qE "vars\\.VERJSON_LANE_FALLBACK|ubuntu-[A-Za-z0-9]" <<<"$selector"; then
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
  if grep -qE "vars\\.VERJSON_LANE_FALLBACK|ubuntu-[A-Za-z0-9]" <<<"$selector"; then
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

# The subtlest way to get a green check out of a check that enforced nothing:
# point it at real files it cannot read. Files present but zero jobs parsed means
# the parser did not understand the tree, not that the tree is clean — so it is
# undetermined even though the sweep ran. Reported after the rules rather than
# before, so a violation that WAS found is still reported as a violation.
[ "$violations" -eq 0 ] || exit 1
[ "$jobs_seen" -gt 0 ] \
  || undetermined "parsed ${#workflow_files[@]} workflow file(s) under $workflow_dir but found no jobs"
exit 0

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
done < <(
  for workflow_file in "${workflow_files[@]}"; do
    parse_jobs "$workflow_file"
  done
)

[ "$violations" -eq 0 ] || exit 1
exit 0

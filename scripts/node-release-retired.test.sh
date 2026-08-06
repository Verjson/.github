#!/usr/bin/env bash
# node-release.yml is retired (#460, ADR 0060). semantic-release derives the
# version from commit subjects at merge time; ADR 0038 replaced that with a
# dispatched release that names its own version.
#
# Retirement here is a refusal, not a deletion, so the properties worth pinning
# are the ones that make the refusal unavoidable and useful: it runs first, it
# is unconditional, it actually exits non-zero, and it names where to go instead.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
release="$root/.github/workflows/node-release.yml"
step_name='Refuse a release derived from a merge'
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --------------------------------------------------------------------------
# The refusal must be the FIRST step of the job. Anywhere else and the retired
# machinery — npm ci, build, semantic-release tooling — runs before the caller
# is told it should not have.
# --------------------------------------------------------------------------
first_step="$(awk '
  /^  release:$/            { injob = 1 }
  injob && /^    steps:$/   { insteps = 1; next }
  insteps && /^      - /    { print; exit }
' "$release")"

case "$first_step" in
  *"$step_name"*) pass "the refusal is the first step of the release job" ;;
  *) fail "the release job runs '$first_step' before refusing" ;;
esac

# --------------------------------------------------------------------------
# ...and it must be unavoidable. Three edits each leave the step visible while
# letting the retired path run again, and review found the suite covering only
# the first of them:
#
#   if:                 the step is skipped outright
#   continue-on-error:  the step runs, fails, and the job proceeds to publish
#   always()            a later step runs regardless of the refusal
#
# The third is not hypothetical — the retired job carried `if: always()` on its
# cache-upload step, which really did execute after the refusal.
# --------------------------------------------------------------------------
step_block="$(awk -v name="$step_name" '
  index($0, name) && /^      - name:/ { capture = 1; print; next }
  capture && /^      - /              { exit }
  capture                             { print }
' "$release")"

if [ -z "$step_block" ]; then
  fail "no step named '$step_name' in $release"
elif printf '%s\n' "$step_block" | grep -qE '^        if:'; then
  fail "the refusal carries an if: condition, so it can be skipped"
elif printf '%s\n' "$step_block" | grep -qE '^        continue-on-error:'; then
  fail "the refusal is continue-on-error, so the job proceeds past it"
else
  pass "the refusal is unconditional and fatal"
fi

# Comment lines stripped first — this file explains `always()` in prose, and a
# guard that cannot tell the explanation from the expression is unusable.
grep -vE '^[[:space:]]*#' "$release" | grep -qF 'always()' \
  && fail "a step runs with always(), so it survives the refusal" \
  || pass "no step outlives the refusal via always()"

# --------------------------------------------------------------------------
# Everything above is scoped to the `release` job. A second job never passes
# through the refusal at all, so the job count is part of the contract rather
# than an incidental property. Review demonstrated the gap: appending a job
# that runs semantic-release directly left the suite fully green.
# --------------------------------------------------------------------------
job_count="$(awk '/^jobs:$/ { injobs = 1; next }
                  injobs && /^[^ ]/ { exit }
                  injobs && /^  [A-Za-z0-9_-]+:$/ { n++ }
                  END { print n + 0 }' "$release")"
[ "$job_count" -eq 1 ] \
  && pass "the retired workflow declares only the refused job" \
  || fail "$release declares $job_count jobs; one of them bypasses the refusal"

# --------------------------------------------------------------------------
# Execute the real block rather than asserting on its text: a step that says
# `exit 1` inside a heredoc, a comment, or an unreached branch reads the same
# to grep and does nothing at runtime.
# --------------------------------------------------------------------------
printf '%s\n' "$step_block" | awk '
  /^        run: \|$/ { capture = 1; next }
  capture && /^        [^ ]/ { exit }
  capture { print }
' | sed 's/^          //' >"$sandbox/refuse.sh"

# Bounded, not merely non-empty: the terminator is indentation, so a reshaped
# step could silently extend the extraction into unrelated YAML and every
# assertion below would then be passing on code the step never runs.
extracted_lines="$(wc -l <"$sandbox/refuse.sh" | tr -d ' ')"
if [ ! -s "$sandbox/refuse.sh" ] ||
   [ "$extracted_lines" -gt 10 ] ||
   ! grep -q 'echo' "$sandbox/refuse.sh"; then
  fail "could not extract the refusal's run block from $release (got $extracted_lines lines)"
  echo "$fails test(s) failed."
  exit 1
fi

output="$(
  CALLER_EVENT=push CALLER_REPO=Verjson/example \
    bash -c 'set -euo pipefail; . "$0"' "$sandbox/refuse.sh" 2>&1
)"
status=$?

[ "$status" -ne 0 ] \
  && pass "the refusal exits non-zero when the workflow is called" \
  || fail "node-release.yml still lets a caller proceed (#460)"

# --------------------------------------------------------------------------
# A refusal that does not say where to go instead is a broken workflow, not a
# retirement. This is the whole reason the file survives deletion.
# --------------------------------------------------------------------------
case "$output" in
  *changelog-release.yml*) pass "the refusal names its replacement workflow" ;;
  *) fail "the refusal does not name changelog-release.yml" ;;
esac

# ...and it must still be callable, or the caller gets "workflow not found"
# from GitHub instead of the message above.
grep -q '^  workflow_call:$' "$release" \
  && pass "the retired workflow is still resolvable by its callers" \
  || fail "workflow_call was removed, so callers cannot reach the refusal"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1

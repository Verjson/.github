#!/usr/bin/env bash
# Write the released form of the unreleased fragments into the job summary.
#
# A released snapshot keeps only each entry's title and lead paragraph, and can
# never be edited afterwards (ADR 0059). So the released form is the one nobody
# sees until it is already permanent. This prints it while the fragments can
# still change.
#
# Informational only. The caller has already decided its verdict; this never
# alters one, and it exits 0 even when the render fails. Both callers run it
# only on a passing check, which is why the warning below can say so.
#
# It lives in a script rather than inline in each workflow because it has two
# callers — changelog-validate.yml and generated-artifacts.yml — and both reach
# it through the contract checkout they already make at contract_ref. A
# composite action cannot serve them: `uses:` cannot be interpolated, so a
# reusable workflow has no way to name an action at the ref its caller pinned.
#
# usage: changelog-preview.sh <engine> <contract-ref>
#   reads GITHUB_WORKSPACE, LEGACY_DIR, GITHUB_STEP_SUMMARY from the environment
set -uo pipefail

engine="$1"
contract_ref="$2"

args=(--repo-root "${GITHUB_WORKSPACE:-.}")
shown=(--repo-root .)
if [ -n "${LEGACY_DIR:-}" ]; then
  args+=(--legacy-dir "$LEGACY_DIR")
  shown+=(--legacy-dir "$LEGACY_DIR")
fi

# The remedy is the command this job ran, against the engine path this job used.
# Under ADR 0038 the engine lives only in Verjson/.github and no consumer commits
# scripts/changelog.py, so naming that path would send every consumer to "No such
# file or directory". --repo-root is shown as `.` because $GITHUB_WORKSPACE
# exists only on a runner.
engine_cmd='python3 .changelog-contract/scripts/changelog.py'

# A preview that FAILED is still reported, so "no unreleased fragments" and "the
# renderer broke" never look alike (#399). An older pinned engine has no
# --as-released and lands in that branch, which is the correct, visible outcome.
preview_rc=0
preview="$(python3 "$engine" render-next "${args[@]}" --as-released 2>&1)" \
  || preview_rc=$?

if [ "$preview_rc" -ne 0 ]; then
  case "$preview" in
    *'no unreleased fragments'*)
      printf 'ok - no unreleased fragments, so there is nothing to preview\n' ;;
    *)
      # An annotation shows one line, so a multi-line failure (a traceback, an
      # argparse usage block) would arrive with its reason cut off. Collapsed
      # rather than truncated.
      printf '::warning title=Release-note preview unavailable::%s\n' \
        "The changelog check itself PASSED and this does not change that verdict. Engine Verjson/.github@$contract_ref said: $(printf '%s' "$preview" | tr '\n' ' ' | cut -c1-400)" ;;
  esac
  exit 0
fi

# A job summary is capped, and a preview cut off mid-entry that does not SAY it
# was cut off is worse than none: it reads as a complete release note that is
# missing entries.
preview_note=''
if [ "${#preview}" -gt 65536 ]; then
  preview_note="$(printf \
    '\n\n_Truncated for the job summary. For the whole thing, run:_\n\n    %s render-next %s --as-released\n' \
    "$engine_cmd" "${shown[*]}")"
fi
{
  printf '<details><summary>Release notes this would publish</summary>\n\n'
  printf '%s' "$preview" | head -c 65536
  printf '%s\n\n</details>\n' "$preview_note"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
printf 'ok - release-note preview written to the job summary\n'

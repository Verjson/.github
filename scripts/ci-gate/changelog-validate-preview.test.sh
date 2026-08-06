#!/usr/bin/env bash
# Tests for the release-note preview in changelog-validate.yml (Verjson/.github#449).
#
# ADR 0059 makes a released snapshot immutable, and ADR 0055 put the preview in
# generated-artifacts.yml — which #437 keeps every adopter off, so the preview
# reached nobody. It now also runs in changelog-validate.yml, the workflow all of
# them do call. Measured before the fix on verjson-authn#154's own check run:
# output.title null, summary length 0.
#
# House method: awk-extract the exact `run:` block from the workflow so the test
# cannot drift from what CI runs, then execute it against a fixture repository.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
workflow="$repo_root/.github/workflows/changelog-validate.yml"
shared_preview="$repo_root/scripts/changelog-preview.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$workflow" ] && [ -f "$shared_preview" ] \
  || { echo "FAIL - changelog-validate.yml or the shared preview script is missing"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# extract_run <step name> -> the step's run: body, dedented.
# Keyed on the step name because these steps carry no id:. Stops at the first
# non-blank line indented less than the block body, which is the next step.
extract_run() {
  awk -v want="      - name: $1" '
    $0 == want { in_step = 1; next }
    in_step && $0 == "        run: |" { in_run = 1; next }
    in_run {
      if ($0 != "" && $0 !~ /^          /) { exit }
      sub(/^          /, "")
      print
    }
  ' "$workflow"
}

preview_body="$tmp/preview-step.sh"
extract_run 'Preview the release notes this would publish' >"$preview_body"
[ -s "$preview_body" ] \
  && pass "the preview step exists in changelog-validate.yml and its body extracts" \
  || { fail "no preview step found in changelog-validate.yml"; echo "1 test(s) failed."; exit 1; }

# A consumer repository laid out the way the workflow's own checkout steps leave
# it: the consumer at $GITHUB_WORKSPACE, the contract at .changelog-contract.
make_repo() { # make_repo <path>
  local ws="$1"
  mkdir -p "$ws/NEXT" "$ws/.changelog-contract/scripts"
  cp "$repo_root/scripts/changelog.py" "$ws/.changelog-contract/scripts/changelog.py"
  # Copied at whatever mode the repository carries, never chmod'd here: doing
  # that is what let the script ship at 644 with these tests green.
  cp "$shared_preview" "$ws/.changelog-contract/scripts/changelog-preview.sh"
  cat >"$ws/NEXT/2026-08-06-issue-449-example.md" <<'FRAGMENT'
---
date: 2026-08-06
issue: 449
title: 'fix(changelog): example entry'
---

The lead paragraph, which is what a release note carries.

## Why

The argument beneath it, which a release note does not carry.
FRAGMENT
}

run_step() { # run_step <workspace> [env assignments...]
  local ws="$1"; shift
  ( cd "$ws" && env GITHUB_WORKSPACE="$ws" GITHUB_STEP_SUMMARY="$ws/summary.md" \
      CONTRACT_REF=0123456789abcdef0123456789abcdef01234567 LEGACY_DIR='' \
      "$@" bash "$preview_body" ) 2>&1
}

# --------------------------------------------------------------------------
# The preview reaches the job summary at all — the thing that was measurably
# absent on every adopter.
# --------------------------------------------------------------------------
ws="$tmp/clean"
make_repo "$ws"
out="$(run_step "$ws")"
rc=$?
[ "$rc" -eq 0 ] && grep -q 'Release notes this would publish' "$ws/summary.md" \
  && pass "the preview step writes the release-note preview to the job summary" \
  || fail "no preview in the job summary (rc=$rc): $out"

# Released shape, not the diary: an adopter reading the diary would approve text
# the release will not carry, which is worse than seeing nothing.
grep -q 'The lead paragraph, which is what a release note carries.' "$ws/summary.md" \
  && ! grep -q 'The argument beneath it' "$ws/summary.md" \
  && pass "the preview shows the RELEASED shape — lead kept, argument dropped" \
  || fail "the preview is not the released shape: $(cat "$ws/summary.md")"

# --------------------------------------------------------------------------
# Informational, never a verdict. A repository with nothing unreleased, and one
# whose engine cannot render, both leave the check passing — and are told apart
# from each other, so a broken renderer never reads as an empty NEXT/ (#399).
# --------------------------------------------------------------------------
ws="$tmp/empty"
make_repo "$ws"
rm "$ws/NEXT/2026-08-06-issue-449-example.md"
out="$(run_step "$ws")"
rc=$?
[ "$rc" -eq 0 ] && grep -q 'nothing to preview' <<<"$out" \
  && ! grep -q 'Release-note preview unavailable' <<<"$out" \
  && pass "an empty NEXT/ is reported as nothing to preview, not as a broken renderer" \
  || fail "an empty NEXT/ was misreported (rc=$rc): $out"

ws="$tmp/broken-engine"
make_repo "$ws"
printf 'import sys\nsys.stderr.write("Traceback\\nValueError: the engine broke\\n")\nsys.exit(1)\n' \
  >"$ws/.changelog-contract/scripts/changelog.py"
out="$(run_step "$ws")"
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a failing renderer does not fail the changelog check" \
  || fail "a failed preview took the check down with it (rc=$rc): $out"

grep -q '::warning title=Release-note preview unavailable::.*ValueError: the engine broke' <<<"$out" \
  && pass "the failure reason survives onto the single line an annotation shows" \
  || fail "the preview failure reason was swallowed or cut: $out"

# --------------------------------------------------------------------------
# Ref skew. contract_ref and the ref this workflow was called at can disagree
# without anything failing, and an older contract has no preview script. Say so
# rather than passing silently — silence is what #449 was.
# --------------------------------------------------------------------------
ws="$tmp/old-contract"
make_repo "$ws"
rm "$ws/.changelog-contract/scripts/changelog-preview.sh"
out="$(run_step "$ws")"
rc=$?
[ "$rc" -eq 0 ] \
  && grep -q 'has no scripts/changelog-preview.sh' <<<"$out" \
  && grep -q 'check itself PASSED' <<<"$out" \
  && pass "a contract checkout without the preview script warns and keeps the check green" \
  || fail "a missing preview script was silent or fatal (rc=$rc): $out"

# --------------------------------------------------------------------------
# File mode. A fixture cannot observe the mode of the committed file unless it
# is asked to, and the first cut of this PR shipped the script at 644 with every
# other assertion green: the callers gated on -x, so a real adopter checkout
# would have taken the warning branch forever. Two independent guards, because
# either alone is a single point of silence.
# --------------------------------------------------------------------------
[ -x "$shared_preview" ] \
  && pass "the committed preview script is executable" \
  || fail "scripts/changelog-preview.sh is not executable ($(stat -c '%a' "$shared_preview"))"

# And the callers must not depend on that bit anyway — a checkout that loses
# modes (an archive export, a copy through a filesystem without them) still has
# to produce the preview rather than the warning.
ws="$tmp/no-exec-bit"
make_repo "$ws"
chmod 644 "$ws/.changelog-contract/scripts/changelog-preview.sh"
out="$(run_step "$ws")"
rc=$?
[ "$rc" -eq 0 ] \
  && grep -q 'Release notes this would publish' "$ws/summary.md" \
  && ! grep -q 'Release-note preview unavailable' <<<"$out" \
  && pass "a non-executable preview script still previews, rather than warning" \
  || fail "the caller depends on the execute bit (rc=$rc): $out"

for caller in "$workflow" "$repo_root/.github/workflows/generated-artifacts.yml"; do
  ! grep -q '\[ -x "\$preview' "$caller" \
    && pass "$(basename "$caller") does not gate the preview on an execute bit" \
    || fail "$(basename "$caller") gates on -x, so a lost mode silently disables the preview"
done

# --------------------------------------------------------------------------
# One implementation, two callers. The preview only stayed missing here for as
# long as it did because each workflow carried its own copy; assert both reach
# the same script rather than re-inlining it.
# --------------------------------------------------------------------------
generated="$repo_root/.github/workflows/generated-artifacts.yml"
for caller in "$workflow" "$generated"; do
  grep -q 'scripts/changelog-preview.sh' "$caller" \
    && pass "$(basename "$caller") reaches the preview through the shared script" \
    || fail "$(basename "$caller") does not use scripts/changelog-preview.sh"
done

for caller in "$workflow" "$generated"; do
  ! grep -q -- 'render-next .*--as-released' "$caller" \
    && pass "$(basename "$caller") does not re-inline a render of its own" \
    || fail "$(basename "$caller") renders inline, so the two copies can drift again"
done

# The verdict-bearing step must not be the one that previews: a preview that
# could fail the check would make an immutable-snapshot warning block a merge.
validate_body="$tmp/validate-step.sh"
extract_run 'Validate fragments and pull-request policy' >"$validate_body"
[ -s "$validate_body" ] && ! grep -q 'changelog-preview.sh' "$validate_body" \
  && pass "the verdict step does not preview, so a preview cannot decide a verdict" \
  || fail "the preview runs inside the verdict-bearing step"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
else
  echo "$fails test(s) failed."
  exit 1
fi

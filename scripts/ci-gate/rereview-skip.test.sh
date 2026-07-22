#!/usr/bin/env bash
# Pins the merge gate's "base-merge-only re-fire" skip (Verjson/.github#120).
# When a PR's net diff is byte-identical to the last APPROVED review (only a
# base-merge/rebase was added since), the gate reuses the prior approval and
# skips the paid model review. This extracts the exact `run:` block of the
# "Decide whether to skip re-review" step from ai-review-merge.yml (single
# source of truth — no drift) and drives it against stubbed `gh` + `git`.
#
# Fail-closed is the whole point: the skip fires ONLY when a prior APPROVAL
# marker exists AND its patchid is non-empty AND equals the current non-empty
# patch-id. Anything ambiguous (no marker, different diff, unknown patch-id, a
# blocking-only record) must fall through to the full review. Plain bash + awk
# + jq; no dependency.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

script="$tmp/rereview.sh"
awk '
  $0 == "      - name: Decide whether to skip re-review (unchanged diff)" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    exit  # end of this run block — do not spill into later steps
  }
' "$wf" >"$script"
if ! grep -q 'patch-id' "$script" || ! grep -q 'skip_model' "$script"; then
  echo "FAIL - could not extract the re-review skip run block from $wf"
  exit 1
fi

# Stub git: driven by MB (merge-base), DIFF (net diff), PID (patch-id).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
  fetch)      exit 0 ;;
  merge-base) [ -n "${MB:-}" ] && { echo "$MB"; exit 0; } || exit 1 ;;
  diff)       printf '%s' "${DIFF:-}"; exit 0 ;;
  patch-id)   cat >/dev/null; [ -n "${PID:-}" ] && echo "$PID 0000000000000000000000000000000000000000"; exit 0 ;;
  *)          exit 0 ;;
esac
GIT
chmod +x "$tmp/bin/git"

# Stub gh: baseRefName -> BASE_REF; reviews,comments -> raw PRDATA JSON.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
jsonarg=""
for ((i=1;i<=$#;i++)); do
  if [ "${!i}" = "--json" ]; then j=$((i+1)); jsonarg="${!j}"; fi
done
case "$jsonarg" in
  baseRefName)       printf '%s' "${BASE_REF:-main}" ;;
  reviews,comments)  printf '%s' "${PRDATA:-{\}}" ;;
  *)                 printf '{}' ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

# run_rereview: drives the extracted block, writes outputs to GITHUB_OUTPUT.
run_rereview() {
  export PATH="$tmp/bin:$PATH" TARGET_REPO="Verjson/foo" PR_NUMBER=7
  export GITHUB_OUTPUT="$tmp/out.txt"
  : >"$GITHUB_OUTPUT"
  bash "$script" >/dev/null 2>&1
}
skip_is() { grep -qx "skip_model=$1" "$GITHUB_OUTPUT"; }
out_has() { grep -qF "$1" "$GITHUB_OUTPUT"; }

approved() { # approved <patchid>
  printf '{"reviews":[{"state":"APPROVED","submittedAt":"2026-07-22T10:00:00Z","body":"looks good\\n\\n<!-- ai-review-head:aaa111 patchid:%s model:haiku -->"}],"comments":[]}' "$1"
}
blocking() { # blocking <patchid>
  printf '{"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2026-07-22T10:00:00Z","body":"has a bug\\n\\n<!-- ai-review-head:aaa111 patchid:%s model:haiku -->"}],"comments":[]}' "$1"
}

# (a) matching patch-id + prior approval -> skip.
MB=base1 DIFF="+net change" PID=PIDMATCH PRDATA="$(approved PIDMATCH)" run_rereview
{ skip_is true && out_has "patch_id=PIDMATCH"; } &&
  pass "matching patch-id + prior approval -> skip_model=true" ||
  fail "matching patch-id + approval did not skip"

# (b) different patch-id -> full review.
MB=base1 DIFF="+net change" PID=PIDNOW PRDATA="$(approved PIDOLD)" run_rereview
skip_is false &&
  pass "different patch-id -> skip_model=false" ||
  fail "different patch-id must not skip"

# (c) no prior marker -> full review.
MB=base1 DIFF="+net change" PID=PIDNOW PRDATA='{"reviews":[],"comments":[]}' run_rereview
skip_is false &&
  pass "no prior approval marker -> skip_model=false" ||
  fail "absent marker must not skip"

# (d) unknown current patch-id (empty net diff) -> full review, never skip.
MB=base1 DIFF="" PID=PIDMATCH PRDATA="$(approved PIDMATCH)" run_rereview
skip_is false &&
  pass "empty/unknown current patch-id -> skip_model=false" ||
  fail "unknown current patch-id must not skip"

# (d2) no merge-base found -> patch-id unknown -> full review.
MB="" DIFF="+net change" PID=PIDMATCH PRDATA="$(approved PIDMATCH)" run_rereview
skip_is false &&
  pass "no merge-base -> skip_model=false" ||
  fail "missing merge-base must not skip"

# (e) a prior BLOCKING marker with a matching patchid does NOT skip.
MB=base1 DIFF="+net change" PID=PIDMATCH PRDATA="$(blocking PIDMATCH)" run_rereview
skip_is false &&
  pass "blocking-only marker (matching patchid) -> skip_model=false" ||
  fail "a blocking record must never authorize a skip"

# (f) self-gate approval-comment fallback (matching patchid) -> skip.
MB=base1 DIFF="+net change" PID=PIDMATCH \
  PRDATA='{"reviews":[],"comments":[{"createdAt":"2026-07-22T10:00:00Z","body":"✅ **Merge gate: approved verdict**\n\nlgtm\n\n<!-- ai-review-head:aaa111 patchid:PIDMATCH model:haiku -->"}]}' \
  run_rereview
skip_is true &&
  pass "approval-comment fallback (matching patchid) -> skip_model=true" ||
  fail "self-gate approval comment must authorize a skip"

# (g) newest approval wins: an older approval matches but the newest does not.
MB=base1 DIFF="+net change" PID=PIDNOW \
  PRDATA='{"reviews":[{"state":"APPROVED","submittedAt":"2026-07-22T09:00:00Z","body":"old\n<!-- ai-review-head:old patchid:PIDNOW model:haiku -->"},{"state":"APPROVED","submittedAt":"2026-07-22T11:00:00Z","body":"new\n<!-- ai-review-head:new patchid:PIDLATER model:haiku -->"}],"comments":[]}' \
  run_rereview
skip_is false &&
  pass "newest approval decides (stale matching approval does not skip)" ||
  fail "must compare against the most recent approval only"

# (h) skip path synthesizes an approved verdict for the deterministic submit.
MB=base1 DIFF="+net change" PID=PIDMATCH PRDATA="$(approved PIDMATCH)" run_rereview
{ out_has "skip_verdict" && grep -q '"blocking":false' "$GITHUB_OUTPUT"; } &&
  pass "skip emits a synthesized approved (blocking=false) verdict" ||
  fail "skip must emit an approved verdict for the submit step"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi

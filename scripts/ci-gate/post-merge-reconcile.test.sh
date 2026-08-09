#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/ai-post-merge.yml"
script="$root/scripts/ci-gate/post-merge-reconcile.sh"
grep -q 'pull_request_target:' "$workflow"
grep -q 'github.event.pull_request.merged == true' "$workflow"
grep -q 'ai-review-authorization:' "$workflow"
grep -q 'ai-review-run:' "$workflow"
grep -q 'path == ".github/workflows/ai-review-merge.yml"' "$workflow"
grep -q 'ref: \${{ github.event.pull_request.base.sha }}' "$workflow"
! grep -Eq 'gh pr merge|workflow run ai-review-merge|sleep [0-9]' "$workflow" "$script"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s\n' "${EXISTING:-0}" ;;
  "issue create") printf 'create %s\n' "$*" >>"$GH_LOG" ;;
  "api repos/"*) printf '%s\n' "${LIVE_SHA:-}" ;;
  "api --method") printf 'delete %s\n' "$*" >>"$GH_LOG" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"
export TARGET_REPO=Verjson/example PR_NUMBER=7 HEAD_REPO=Verjson/example HEAD_REF=feature/test
export BASE_REF=main DEFAULT_BRANCH=main MERGED_HEAD_SHA=1111111111111111111111111111111111111111
export LIVE_SHA="$MERGED_HEAD_SHA"
export ATTESTATION_FILE="$tmp/attestation.json"
jq -n '{followups:[{location:"src/a.ts:3",note:"Add coverage."},{location:"src/a.ts:3",note:"Add coverage."}]}' >"$ATTESTATION_FILE"
bash "$script"
[ "$(grep -c '^create ' "$GH_LOG")" -eq 1 ]
grep -q '^delete ' "$GH_LOG"
: >"$GH_LOG"
EXISTING=1 HEAD_REPO=someone/fork bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 LIVE_SHA=2222222222222222222222222222222222222222 bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 HEAD_REF=main LIVE_SHA="$MERGED_HEAD_SHA" bash "$script"
[ ! -s "$GH_LOG" ]

: >"$GH_LOG"
EXISTING=1 HEAD_REF=release BASE_REF=release DEFAULT_BRANCH=main LIVE_SHA="$MERGED_HEAD_SHA" bash "$script"
[ ! -s "$GH_LOG" ]
echo "All tests passed."

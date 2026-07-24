#!/usr/bin/env bash
# Governance guard for the rework reconciler (ADR 0006 — observe-and-report).
# These assertions are the machine-checkable form of "the AI must not own or
# mutate the mechanism that grades AI-authored work": the workflow may only
# read PRs and open an issue, and its permissions must not grant PR/content
# writes. If a future edit tries to make the reconciler act on a gate, this
# fails.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
wf="$root/.github/workflows/rework-reconcile.yml"
recon="$here/rework-reconcile.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$wf" ] || { echo "FAIL - workflow not found: $wf"; exit 1; }
[ -f "$recon" ] || { echo "FAIL - reconciler not found: $recon"; exit 1; }

# --- triggers ---
grep -Eq '^\s*schedule:' "$wf" && pass "runs on a schedule" || fail "no schedule trigger"
grep -Eq '^\s*workflow_dispatch:' "$wf" && pass "supports manual dispatch" || fail "no workflow_dispatch"

# --- least-privilege permissions (observe-only) ---
# Assert against real YAML, not the explanatory comments — strip comment lines.
code() { grep -Ev '^\s*#' "$1"; }
grep -Eq '^\s*issues:\s*write' "$wf" && pass "grants issues: write (to open the report)" || fail "missing issues: write"
grep -Eq '^\s*contents:\s*read' "$wf" && pass "grants contents: read" || fail "missing contents: read"
code "$wf" | grep -Eq 'pull-requests:\s*write' && fail "MUST NOT grant pull-requests: write" || pass "no pull-requests: write grant"
code "$wf" | grep -Eq 'contents:\s*write' && fail "MUST NOT grant contents: write" || pass "no contents: write grant"

# --- self-hosted pool (no Docker socket; matches the repo's other workflows) ---
grep -Eq 'runs-on:\s*\[self-hosted' "$wf" && pass "runs on the self-hosted pool" || fail "not pinned to self-hosted"

# --- no gate/PR mutation anywhere in the workflow or the reconciler ---
mutations='gh pr merge|gh pr close|gh pr edit|gh pr review|--merge|--squash|--rebase|merge_pull_request|-X (PUT|POST|PATCH|DELETE)|branch protection|rulesets?'
for f in "$wf" "$recon"; do
  if grep -Eiq "$mutations" "$f"; then
    fail "gate/PR-mutating call found in $(basename "$f")"
  else
    pass "no gate/PR mutation in $(basename "$f")"
  fi
done

# --- the only write verb is issue creation ---
grep -q 'gh issue create' "$wf" && pass "the sole write is gh issue create" || fail "expected gh issue create as the report sink"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1

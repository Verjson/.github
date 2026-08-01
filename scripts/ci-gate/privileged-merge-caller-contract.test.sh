#!/usr/bin/env bash
# The privileged-merge reusable split rests on a two-sided contract, and BOTH
# sides fail silently when broken:
#
#   caller job key `privileged_merge`  +  exclusion literal in ai-review-merge.yml
#
# A reusable call publishes its check as "<caller job> / <callee job>". The gate
# filters required checks by exact name equality, so it must exclude
# "privileged_merge / privileged_merge" — and that literal only ever matches if
# the caller's job key is contractually `privileged_merge`. A consumer who
# writes `merge:` produces "merge / privileged_merge", which the gate then
# counts as one of its own required checks and waits on forever, while that
# check waits for the gate. Nothing reports the cause.
#
# Pinning only one side is useless, so this pins both, plus the generator that
# keeps a hand-written caller from drifting back in.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gate="$repo_root/.github/workflows/ai-review-merge.yml"
canonical="$repo_root/.github/workflows/ai-privileged-merge.yml"
gen="$repo_root/scripts/gen-privileged-merge-caller.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

for f in "$gate" "$canonical" "$gen"; do
  [ -f "$f" ] || { echo "FAIL - missing $f"; exit 1; }
done

# --- side 1: the gate excludes both published shapes -------------------------
# Two filter sites (the wait loop and the pre-merge re-check). Both must carry
# both literals; pinning the count stops one copy from drifting, the same way
# hold.test.sh pins its two hold predicates.
bare=$(grep -c '\$n != "privileged_merge" and' "$gate")
reusable=$(grep -c '\$n != "privileged_merge / privileged_merge")\]' "$gate")

[ "$bare" -eq 2 ] \
  && pass "gate excludes the required-workflow shape at both filter sites" \
  || fail "expected 2 bare privileged_merge exclusions, found $bare"

[ "$reusable" -eq 2 ] \
  && pass "gate excludes the reusable-call shape at both filter sites" \
  || fail "expected 2 'privileged_merge / privileged_merge' exclusions, found $reusable"

# --- side 2: the canonical workflow's job key --------------------------------
python3 - "$canonical" <<'PY' && pass "canonical job key is privileged_merge" \
  || fail "canonical job key changed — the reusable check name would change with it"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if list(d["jobs"]) == ["privileged_merge"] else 1)
PY

python3 - "$canonical" <<'PY' && pass "canonical accepts workflow_call with required runner_labels" \
  || fail "canonical workflow_call contract drifted"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
wc = on.get("workflow_call")
if not wc: sys.exit(1)
i = wc.get("inputs", {})
need = {"pr_number", "expected_head_sha", "source_run_id", "runner_labels"}
if not need <= set(i): sys.exit(1)
sys.exit(0 if i["runner_labels"].get("required") is True else 1)
PY

# --- the generated caller honours both sides ---------------------------------
bash "$gen" '["ubuntu-24.04"]' >"$tmp/caller.yml" 2>/dev/null \
  && pass "generator emits a caller" || fail "generator failed"

python3 - "$tmp/caller.yml" <<'PY' && pass "generated caller's job key is privileged_merge" \
  || fail "generated caller job key is not privileged_merge — deadlocks the gate"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if list(d["jobs"]) == ["privileged_merge"] else 1)
PY

python3 - "$tmp/caller.yml" <<'PY' && pass "generated caller pins @main, not a SHA" \
  || fail "generated caller is not pinned to @main"
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1]))
u = d["jobs"]["privileged_merge"]["uses"]
if not u.endswith("@main"): sys.exit(1)
sys.exit(1 if re.search(r"@[0-9a-f]{40}$", u) else 0)
PY

grep -qE '^\s*secrets:\s*inherit\s*$' "$tmp/caller.yml" \
  && pass "generated caller passes secrets: inherit" \
  || fail "generated caller omits secrets: inherit"

# --- the caller stays THIN ---------------------------------------------------
# A fat copy is how the trust logic diverged in the first place. Assert the
# caller carries no trust machinery of its own.
if grep -qE 'ORG_ADMIN_TOKEN|commits/main|trusted_workflow|gh api|gh pr merge|run:' "$tmp/caller.yml"; then
  fail "generated caller contains inline trust logic — it must only delegate"
else
  pass "generated caller is thin: delegates, implements nothing"
fi

# --- concurrency: caller and callee must not share a group -------------------
# A called workflow's concurrency is evaluated in the caller's context, so an
# identical group would put the reusable's job behind the caller job that
# invoked it. Distinct names by construction.
canon_group=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$canonical'))
print(d.get('concurrency',{}).get('group',''))")
call_group=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$tmp/caller.yml'))
print(d.get('concurrency',{}).get('group',''))")

[ -n "$canon_group" ] && [ -n "$call_group" ] && [ "$canon_group" != "$call_group" ] \
  && pass "caller and canonical use distinct concurrency groups" \
  || fail "concurrency groups collide or are missing: '$canon_group' vs '$call_group'"

# Both must be keyed by event, or the dispatched continuation cancels the
# pull_request_target check and leaves a red mark on a merged PR (ADR 0039).
case "$canon_group" in *github.event_name*) pass "canonical concurrency is keyed by event" ;;
  *) fail "canonical concurrency not keyed by event — dispatch will cancel the PR check" ;; esac
case "$call_group" in *github.event_name*) pass "caller concurrency is keyed by event" ;;
  *) fail "caller concurrency not keyed by event" ;; esac

# --- generator input validation ----------------------------------------------
bash "$gen" 'not-json' >/dev/null 2>&1 && fail "generator accepted non-JSON runner_labels" \
  || pass "generator rejects non-JSON runner_labels"
bash "$gen" '[]' >/dev/null 2>&1 && fail "generator accepted empty runner_labels" \
  || pass "generator rejects empty runner_labels"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; fi
echo "$fails test(s) failed."
exit 1

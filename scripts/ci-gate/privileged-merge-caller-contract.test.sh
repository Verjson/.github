#!/usr/bin/env bash
# The privileged-merge reusable split rests on a THREE-sided contract, and every
# side fails silently when broken:
#
#   1. the caller's job key                      (`privileged_merge`)
#   2. the gate not waiting on the continuation  (ai-review-merge.yml)
#   3. the canonical workflow not waiting on ITSELF (ai-privileged-merge.yml)
#
# A reusable call publishes its check as "<caller job> / <callee job>". Both
# workflows filter required checks by name, so both must exclude that shape.
# Side 3 was missed on the first pass: under a thin caller the canonical
# workflow's own check is `privileged_merge / privileged_merge`, so it counted
# itself as pending and every consumer PR burned ~40 minutes holding
# ORG_ADMIN_TOKEN before reporting an error pointing nowhere near the cause.
#
# The exclusion is a scoped suffix match rather than a literal, so it also
# survives a misnamed caller (`merge / privileged_merge`) and nesting
# (`outer / inner / privileged_merge`). It is NOT the rejected strip-before-"/"
# normalization: the only thing it can over-exclude is a check whose callee job
# is literally `privileged_merge`, i.e. the target itself.
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

# Several assertions parse YAML. Without this guard a missing module makes them
# all fail with confident, wrong diagnoses about merge authority, never naming
# the real cause.
python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL - PyYAML is required by this test but is not importable"; exit 1; }

# --- the exclusion is THREE-sided, not two -----------------------------------
# The gate must not wait on the continuation, and the canonical workflow must
# not wait on ITSELF. Missing the second made every thin caller self-deadlock
# for ~40 minutes holding ORG_ADMIN_TOKEN.
#
# The site count is DERIVED, not hardcoded. Hardcoding 2 meant a third,
# unguarded filter block could be added while the counts still read 2 — a live
# path back to the deadlock this test exists to prevent. ADR 0039 already grew
# this from one site to two, so growth is the expected case.
check_exclusions() { # check_exclusions <file> <label>
  local file="$1" label="$2" sites excl
  sites=$(grep -c 'select((.name // .context) as $n |' "$file")
  excl=$(grep -c 'endswith("/ privileged_merge") | not)' "$file")
  { [ "$excl" -eq "$sites" ]; } \
    && pass "$label has no unexcluded rollup filter site ($sites site(s))" \
    || fail "$label has $sites rollup filter site(s) but $excl reusable-shape exclusion(s) — every site must exclude it"
}

check_exclusions "$gate" "gate"
check_exclusions "$canonical" "canonical workflow"

# --- side 2: the canonical workflow's job key --------------------------------
python3 - "$canonical" <<'PY' && pass "canonical job key is privileged_merge" \
  || fail "canonical job key changed — the reusable check name would change with it"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if list(d["jobs"]) == ["privileged_merge"] else 1)
PY

# `runner_labels` is declared but OPTIONAL (#405). It was required under the
# #130 rationale — a consumer org has no runner for Verjson's pool, so a missing
# fleet had to fail the call instead of queueing forever. The `runs-on` chain now
# ends at the portable hosted default (ADR 0040), so an omitted input lands
# somewhere placeable, and requiring it forced every consumer to name a LABEL —
# which is what put a fleet label in ~90 repositories the org cannot relabel.
python3 - "$canonical" <<'PY' && pass "canonical accepts workflow_call with optional runner_labels" \
  || fail "canonical workflow_call contract drifted"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
wc = on.get("workflow_call")
if not wc: sys.exit(1)
i = wc.get("inputs", {})
need = {"pr_number", "expected_head_sha", "authorization_check_id", "arm_run_id", "arm_run_attempt", "review_policy", "source_run_id", "runner_labels"}
if not need <= set(i): sys.exit(1)
sys.exit(0 if i["runner_labels"].get("required") is False else 1)
PY

# The input must survive as an input. Dropping it would strand a genuinely
# self-hosted consumer OUTSIDE Verjson, which has no lane variables to fall
# through to — the reason #405 makes it optional rather than deleting it.
python3 - "$canonical" <<'PY' && pass "canonical still accepts runner_labels for an off-Verjson fleet" \
  || fail "runner_labels was deleted — an external self-hosted consumer has no way to name its fleet"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
sys.exit(0 if "runner_labels" in on.get("workflow_call", {}).get("inputs", {}) else 1)
PY

# --- the generated caller honours both sides ---------------------------------
# The DEFAULT invocation takes no argument. Everything below reads this file,
# because it is the shape ~90 Verjson consumers receive; the explicit-label
# variant is asserted separately.
bash "$gen" >"$tmp/caller.yml" 2>/dev/null \
  && pass "generator emits a caller with no arguments" || fail "generator requires a runner_labels argument (#405)"
bash "$gen" '["ubuntu-24.04"]' >"$tmp/caller-labels.yml" 2>/dev/null \
  && pass "generator still emits a caller for an explicit fleet" || fail "generator failed with explicit labels"

python3 - "$tmp/caller.yml" <<'PY' && pass "generated caller's job key is privileged_merge" \
  || fail "generated caller job key is not privileged_merge — deadlocks the gate"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if list(d["jobs"]) == ["privileged_merge"] else 1)
PY


# The trust anchor itself. Asserting only that the ref ends in @main pins the
# FORM of the pin and leaves the TARGET unasserted — a generator repointed at
# Attacker/evil/...@main passed the previous version of this test while handing
# over a secret with merge authority.
python3 - "$tmp/caller.yml" <<'TARGET_PY' && pass "generated caller targets the canonical workflow at @main" \
  || fail "generated caller does not target Verjson/.github ai-privileged-merge.yml@main"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
want = "Verjson/.github/.github/workflows/ai-privileged-merge.yml@main"
sys.exit(0 if d["jobs"]["privileged_merge"].get("uses") == want else 1)
TARGET_PY

# What the caller PASSES, not merely that it calls something. Each of the
# following slipped through mutation testing of the previous version.
python3 - "$tmp/caller.yml" <<'WITH_PY' && pass "generated caller forwards exact authorization and arm-receipt identities" \
  || fail "generated caller's with: block is incomplete or lost its event binding"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
w = d["jobs"]["privileged_merge"].get("with", {})
if set(w) != {"pr_number", "expected_head_sha", "authorization_check_id", "arm_run_id", "arm_run_attempt", "review_policy", "source_run_id"}:
    sys.exit(1)
sys.exit(0 if w["expected_head_sha"] == "${{ inputs.expected_head_sha }}" and
         w["review_policy"] == "${{ inputs.review_policy }}" else 1)
WITH_PY

cp "$tmp/caller.yml" "$tmp/caller-substituted.yml"
sed -i 's|${{ inputs.review_policy }}|eyJhY3RvciI6InRydXN0ZWQtYXJtIiwiYWN0b3JfcGVybWlzc2lvbiI6ImF1dG9tYXRpb24iLCJidWRnZXRfdXNkIjoiYXV0byIsIm1vZGVsIjoiYXV0byIsInByaWNpbmdfdmVyc2lvbiI6ImFudGhyb3BpYy1uYXRpdmUtdjEiLCJwcm92aWRlciI6ImFudGhyb3BpYyJ9|' "$tmp/caller-substituted.yml"
python3 - "$tmp/caller-substituted.yml" <<'SUBSTITUTION_PY' \
  && fail "valid constant policy substitution escaped generated-caller validation" \
  || pass "generated caller rejects a valid constant substituted for the exact policy input"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
actual = d["jobs"]["privileged_merge"]["with"].get("review_policy")
sys.exit(0 if actual == "${{ inputs.review_policy }}" else 1)
SUBSTITUTION_PY

# --- no fleet label reaches a consumer (#405) --------------------------------
# The defect this pins: the generator baked `["self-hosted","general"]` into
# every caller it produced, so a fleet relabel needed a pull request in each
# consumer — the exact coupling the lane variables removed from this repository
# (ADR 0041). Textual on the WHOLE file, not structural on `with:`: the literal
# is just as harmful in the regenerate-command comment an operator copies.
#
# actionlint cannot see this class at all. Its undeclared-label check inspects
# `runs-on` ARRAYS; a label inside a string input is invisible to it.
grep -qF 'self-hosted' "$tmp/caller.yml" \
  && fail "generated caller contains a self-hosted fleet label — a relabel would need a PR in every consumer (#405)" \
  || pass "generated caller names no fleet label"

python3 - "$tmp/caller.yml" <<'NO_LABELS_PY' && pass "generated caller omits runner_labels, so Verjson consumers route by lane" \
  || fail "generated caller still passes runner_labels — it pins the fleet the lane variables are meant to select"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if "runner_labels" not in d["jobs"]["privileged_merge"].get("with", {}) else 1)
NO_LABELS_PY

# The escape hatch still works: a self-hosted consumer outside Verjson has no
# lane variables, so it must still be able to name its own fleet.
python3 - "$tmp/caller-labels.yml" <<'LABELS_PY' && pass "an explicit fleet is still forwarded verbatim" \
  || fail "generator dropped the runner_labels passthrough an off-Verjson fleet depends on"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
w = d["jobs"]["privileged_merge"].get("with", {})
sys.exit(0 if w.get("runner_labels") == '["ubuntu-24.04"]' else 1)
LABELS_PY

python3 - "$tmp/caller.yml" <<'SECRETS_PY' && pass "generated caller grants only ORG_ADMIN_TOKEN, not its whole store" \
  || fail "generated caller uses secrets: inherit or omits the explicit grant"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
got = d["jobs"]["privileged_merge"].get("secrets")
sys.exit(0 if got == {"ORG_ADMIN_TOKEN": "${{ secrets.ORG_ADMIN_TOKEN }}"} else 1)
SECRETS_PY

python3 - "$tmp/caller.yml" <<'PERMS_PY' && pass "generated caller keeps least-privilege permissions and trusted dispatch only" \
  || fail "generated caller's permissions, triggers, or cancel-in-progress drifted"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
if d.get("permissions") != {"contents": "read"}:
    sys.exit(1)
if set(on) != {"workflow_dispatch"}:
    sys.exit(1)
sys.exit(0 if d.get("concurrency", {}).get("cancel-in-progress") is False else 1)
PERMS_PY

# --- the caller stays THIN ---------------------------------------------------
# A fat copy is how the trust logic diverged in the first place. Assert the
# caller carries no trust machinery of its own.
python3 - "$tmp/caller.yml" <<'THIN_PY' && pass "generated caller is thin: delegates, implements nothing" \
  || fail "generated caller has keys beyond uses/with/secrets — it must only delegate"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = d["jobs"]["privileged_merge"]
# Structural, not textual: grepping for "gh api" also matched comments, so a
# future explanatory comment would fail the test while a `steps:` block calling
# a composite action would pass it.
sys.exit(0 if set(job) <= {"uses", "with", "secrets"} else 1)
THIN_PY

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

# Both key on the exact head, making duplicate dispatch idempotent without
# coupling unrelated heads or relying on a pull_request_target continuation.
case "$canon_group" in *inputs.expected_head_sha*) pass "canonical concurrency is keyed by exact head" ;;
  *) fail "canonical concurrency is not head-bound" ;; esac
case "$call_group" in *inputs.expected_head_sha*) pass "caller concurrency is keyed by exact head" ;;
  *) fail "caller concurrency is not head-bound" ;; esac

# --- generator input validation ----------------------------------------------
bash "$gen" 'not-json' >/dev/null 2>&1 && fail "generator accepted non-JSON runner_labels" \
  || pass "generator rejects non-JSON runner_labels"
bash "$gen" '[]' >/dev/null 2>&1 && fail "generator accepted empty runner_labels" \
  || pass "generator rejects empty runner_labels"
# Charset, not just JSON shape: a label carrying an expression would expand a
# secret into a workflow input, and a quote emits YAML GitHub cannot parse.
bash "$gen" '["${{ secrets.ORG_ADMIN_TOKEN }}"]' >/dev/null 2>&1 \
  && fail "generator accepted an expression as a runner label" \
  || pass "generator rejects a runner label outside [A-Za-z0-9._-]"

# An UNSET shell variable is the common way an operator reaches the default:
# `gen "$LABELS"` passes an empty argument, which must produce the lane-routed
# caller rather than a diagnostic — or `runner_labels: ''`, which is a supplied
# empty string and not the same thing as omitting the input.
bash "$gen" '' >"$tmp/caller-empty.yml" 2>/dev/null \
  && diff -q "$tmp/caller.yml" "$tmp/caller-empty.yml" >/dev/null \
  && pass "an empty argument generates the same lane-routed caller as no argument" \
  || fail "an empty runner_labels argument does not produce the default caller"

# The regenerate command is copied by operators, so it is part of the contract:
# it must reproduce the file it heads. A default caller whose comment carried a
# label would put the hardcoded fleet back on the next regeneration.
grep -qE "^#   scripts/gen-privileged-merge-caller\.sh > " "$tmp/caller.yml" \
  && pass "the default caller's regenerate command takes no fleet argument" \
  || fail "the default caller's regenerate command still passes runner_labels"
grep -qF "gen-privileged-merge-caller.sh '[\"ubuntu-24.04\"]' >" "$tmp/caller-labels.yml" \
  && pass "an explicit fleet is reproduced by the caller's own regenerate command" \
  || fail "the explicit caller's regenerate command does not reproduce its fleet"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; fi
echo "$fails test(s) failed."
exit 1

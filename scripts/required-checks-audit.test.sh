#!/usr/bin/env bash
# Unit tests for scripts/required-checks-audit.sh against a stubbed `gh`.
#
# The audit is read-only, so the risk is not that it breaks something — it is
# that it reports "conformant" for a repository that would in fact be wedged the
# moment the rule is written. Every test below is therefore about the audit
# REFUSING to say yes: unclassified repositories, absent contexts, and the one
# shape that looks absent but is fine (a skipped check run).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/required-checks-audit.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - audit script not found"; exit 1; }

mkdir -p "$tmp/bin" "$tmp/checks"
# Stub `gh`. The real one applies `--jq` client-side; a stub that ignored it
# would hand the script raw JSON where it expects a stream, and every lookup
# would read as "nothing found" — the audit would then report every context
# missing and the tests would pass for the wrong reason.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--jq" ] && filter="${args[$((i + 1))]}"
done
emit() { if [ -n "$filter" ]; then jq -r "$filter" "$1"; else cat "$1"; fi; }
sha_of() { for a in "$@"; do case "$a" in *commits/*) s="${a#*commits/}"; printf '%s' "${s%%/*}"; return;; esac; done; }
case "$*" in
  *"/properties/values"*)
    [ "${PROPS_FAIL:-false}" = true ] && exit 1
    emit "$PROPS_FILE"; exit 0 ;;
  *"/pulls?"*)
    [ "${PULLS_FAIL:-false}" = true ] && exit 1
    emit "$PULLS_FILE"; exit 0 ;;
  *"/check-runs"*)
    [ "${CHECKS_FAIL:-false}" = true ] && exit 1
    emit "$CHECKDIR/$(sha_of "$@").json"; exit 0 ;;
  *"/status?"*)
    f="$CHECKDIR/$(sha_of "$@").status.json"
    [ -f "$f" ] || printf '{"statuses":[]}\n' >"$f"
    emit "$f"; exit 0 ;;
  *"orgs/"*"/repos"*)
    printf '%s\n' "${REPOS:-alpha}"; exit 0 ;;
esac
exit 0
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH"
export CHECKDIR="$tmp/checks"
export PROPS_FILE="$tmp/props.json"
export PULLS_FILE="$tmp/pulls.json"
export RCA_ORG=Verjson
export RCA_SAMPLE_PRS=2

stack() { jq -n --arg v "$1" '[{property_name:"verjson-stack", value:$v}]' >"$PROPS_FILE"; }
no_stack() { printf '[]\n' >"$PROPS_FILE"; }
pulls() { jq -n --args '$ARGS.positional | map({merged_at:"2026-08-05T00:00:00Z", head:{sha:.}})' "$@" >"$PULLS_FILE"; }
# Named check runs, all concluded `success` unless a test overrides the file.
head_with() { local sha="$1"; shift; jq -n --args '{check_runs: ($ARGS.positional | map({name:., conclusion:"success"}))}' "$@" >"$CHECKDIR/$sha.json"; }

run_audit() { ( bash "$script" >"$tmp/out.txt" 2>&1; echo "rc=$?" ); }
out() { cat "$tmp/out.txt"; }

# --- an unclassified repository is never called conformant -------------------
no_stack; pulls s1 s2; head_with s1 gate; head_with s2 gate
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'result=unclassified' "$tmp/out.txt"; } \
  && pass "a repository with no verjson-stack property is reported, never guessed" \
  || { fail "an unclassified repository was not flagged ($rc)"; out | sed 's/^/diag - /'; }

# --- a stack with no declared contract is a fault, not an empty contract -----
# An unknown stack whose contract silently resolved to "nothing" would report
# conformant for a repository nobody has thought about.
stack bogus; pulls s1 s2; head_with s1 gate; head_with s2 gate
rc="$(run_audit)"
{ [ "$rc" = "rc=2" ] && grep -q 'unknown-stack' "$tmp/out.txt"; } \
  && pass "an unknown stack is a fault, not an empty core contract" \
  || { fail "an unknown stack did not fault ($rc)"; out | sed 's/^/diag - /'; }

# --- the happy path ----------------------------------------------------------
stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" "changelog / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" "changelog / validate"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a node repository emitting its full core set is conformant" \
  || { fail "a conformant node repository was not recognised ($rc)"; out | sed 's/^/diag - /'; }

# --- THE finding this exists for: a missing context is non-zero --------------
# `changelog / validate` is core for package repositories, and a repository not
# yet wired to the changelog contract emits nothing for it. Requiring it there
# is the permanently-pending wedge.
stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility"
head_with s2 gate "ci / build-test" "ci / eligibility"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'missing-core-contexts' "$tmp/out.txt" && grep -q 'changelog / validate' "$tmp/out.txt"; } \
  && pass "a package repository not wired to the changelog contract is reported as missing it" \
  || { fail "an absent core context was not reported ($rc)"; out | sed 's/^/diag - /'; }

# --- a SKIPPED check run is conformant, not missing --------------------------
# This is the distinction the whole design rests on: a conditional job reports
# `skipped` and satisfies a required check, while a paths-filtered workflow
# reports nothing and wedges. Calling `skipped` missing would send people to fix
# the one shape that is already correct.
stack node
pulls s1 s2
jq -n '{check_runs:[{name:"gate",conclusion:"success"},
                    {name:"ci / build-test",conclusion:"success"},
                    {name:"ci / eligibility",conclusion:"skipped"},
                    {name:"changelog / validate",conclusion:"success"}]}' >"$CHECKDIR/s1.json"
cp "$CHECKDIR/s1.json" "$CHECKDIR/s2.json"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && ! grep -q 'missing-core-contexts' "$tmp/out.txt"; } \
  && pass "a skipped check run satisfies the contract — only an absent one wedges" \
  || { fail "a skipped conditional job was reported as missing ($rc)"; out | sed 's/^/diag - /'; }

# --- stacks carry different contracts ---------------------------------------
# A helm repository must not be judged against node's contexts; if it were, the
# audit would demand `ci / build-test` from a repository that never emits it.
stack helm
pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ]; } \
  && pass "a helm repository is judged against helm's contract, not node's" \
  || { fail "helm was judged against the wrong contract ($rc)"; out | sed 's/^/diag - /'; }

# `pulumi` is deliberately NOT a package stack, so demanding the changelog
# context from it would be a false finding.
stack pulumi
pulls s1 s2
head_with s1 gate "ci / validate" "ci / preview"
head_with s2 gate "ci / validate" "ci / preview"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ]; } \
  && pass "a non-package stack is not required to emit the changelog context" \
  || { fail "pulumi was wrongly required to emit changelog / validate ($rc)"; out | sed 's/^/diag - /'; }

# --- `gate` is universal ------------------------------------------------------
stack actions
pulls s1 s2
head_with s1 "shell-tests"
head_with s2 "shell-tests"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'missing=gate' "$tmp/out.txt"; } \
  && pass "gate is required of every stack, including actions" \
  || { fail "a repository missing gate was called conformant ($rc)"; out | sed 's/^/diag - /'; }

# --- commit statuses count -----------------------------------------------------
# The gate polls check-runs AND statuses; a context delivered as a commit status
# must not be reported missing just because it is not a check run.
stack actions
pulls s1 s2
head_with s1 "shell-tests"
head_with s2 "shell-tests"
printf '{"statuses":[{"context":"gate","state":"success"}]}\n' >"$CHECKDIR/s1.status.json"
printf '{"statuses":[{"context":"gate","state":"success"}]}\n' >"$CHECKDIR/s2.status.json"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ]; } \
  && pass "a context delivered as a commit status counts as present" \
  || { fail "a commit status context was reported missing ($rc)"; out | sed 's/^/diag - /'; }
rm -f "$CHECKDIR"/*.status.json

# --- unreadable APIs do not read as conformant -------------------------------
stack node; pulls s1 s2; head_with s1 gate; head_with s2 gate
rc="$(PULLS_FAIL=true run_audit)"
{ grep -q 'pulls-unreadable' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "an unreadable pulls API is reported, never counted as conformant" \
  || { fail "an API failure was absorbed ($rc)"; out | sed 's/^/diag - /'; }

rc="$(CHECKS_FAIL=true run_audit)"
{ grep -q 'checks-unreadable' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "an unreadable check-runs API is reported, never counted as conformant" \
  || { fail "an unreadable check API was absorbed ($rc)"; out | sed 's/^/diag - /'; }

# --- a repository with no merged PRs is not conformant by default ------------
stack node; printf '[]\n' >"$PULLS_FILE"
rc="$(run_audit)"
{ grep -q 'no-merged-prs' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a repository with no merged PRs is reported, not silently conformant" \
  || { fail "an unaudited repository was counted as conformant ($rc)"; out | sed 's/^/diag - /'; }

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi

#!/usr/bin/env bash
# Unit tests for scripts/required-checks-audit.sh against a stubbed `gh`.
#
# The audit is read-only, so the risk is not that it breaks something — it is
# that it reports "conformant" for a repository that would in fact be wedged the
# moment the rule is written. Every test below is therefore about the audit
# REFUSING to say yes: unclassified repositories, absent contexts, and the one
# shape that looks absent but is fine (a skipped check run).
# shellcheck disable=SC2015  # Compact assertions intentionally use A && pass || fail.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/required-checks-audit.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - audit script not found"; exit 1; }
contract="$here/../.github/required-check-contract.json"

if grep -qE 'gh api .*(-X|--method)|gh (repo|api) (edit|delete)' "$script"; then
  fail "read-only audit contains a GitHub mutation path"
else
  pass "audit contains no GitHub mutation command"
fi

jq -e '
  .mutation_authorized == false and
  .ruleset_plan.requested_enforcement == "evaluate" and
  .ruleset_plan.human_gate_required == true and
  .universal_contexts == ["gate"] and
  .stacks.node.contexts == ["ci / build-test", "ci / eligibility", "generated-artifacts / validate"] and
  .stacks.ui.contexts == ["ci / build-test", "generated-artifacts / validate"] and
  .stacks.helm.contexts == ["ci / lint-template", "generated-artifacts / validate"] and
  .caller_job_names.generated_artifacts == "generated-artifacts" and
  (.caller_job_names | has("changelog") | not) and
  .stacks.pulumi.contexts == ["ci / validate", "ci / preview"] and
  .stacks.actions.contexts == ["shell-tests"] and
  ([.ruleset_plan.rulesets[].name] | sort) == ([
    "changelog-contract-required", "core-checks-actions", "core-checks-helm",
    "core-checks-node", "core-checks-pulumi", "core-checks-ui",
    "core-checks-universal"
  ] | sort)
' "$contract" >/dev/null \
  && pass "declared contract pins every context and a human-gated evaluate plan" \
  || fail "required-check declaration or non-mutating plan drifted"

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
  *"orgs/"*"/repos"*)
    [ "${REPOS_FAIL:-false}" = true ] && exit 1
    [[ " $* " == *" --paginate "* ]] || exit 65
    emit "$REPOS_FILE"; exit 0 ;;
  *"/properties/values"*)
    [ "${PROPS_FAIL:-false}" = true ] && exit 1
    emit "$PROPS_FILE"; exit 0 ;;
  *"/contents/.github/workflows/"*)
    [ "${WORKFLOWS_FAIL:-false}" = true ] && exit 1
    emit "$WORKFLOW_CONTENT_FILE"; exit 0 ;;
  *"/contents/.github/workflows"*)
    [ "${WORKFLOWS_FAIL:-false}" = true ] && exit 1
    emit "$WORKFLOW_LIST_FILE"; exit 0 ;;
  *"/pulls?"*)
    [ "${PULLS_FAIL:-false}" = true ] && exit 1
    emit "$PULLS_FILE"; exit 0 ;;
  *"/check-runs"*)
    [ "${CHECKS_FAIL:-false}" = true ] && exit 1
    [[ " $* " == *" --paginate "* ]] || exit 65
    emit "$CHECKDIR/$(sha_of "$@").json"; exit 0 ;;
  *"/status?"*)
    [ "${STATUSES_FAIL:-false}" = true ] && exit 1
    [[ " $* " == *" --paginate "* ]] || exit 65
    f="$CHECKDIR/$(sha_of "$@").status.json"
    [ -f "$f" ] || printf '{"statuses":[]}\n' >"$f"
    emit "$f"; exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 64
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH"
export CHECKDIR="$tmp/checks"
export PROPS_FILE="$tmp/props.json"
export PULLS_FILE="$tmp/pulls.json"
export REPOS_FILE="$tmp/repos.json"
export WORKFLOW_LIST_FILE="$tmp/workflows.json"
export WORKFLOW_CONTENT_FILE="$tmp/workflow-content.json"
export RCA_ORG=Verjson
export RCA_SAMPLE_PRS=2
export RCA_REPOS=alpha

workflow_for() {
  local stack="$1" stack_workflow=''
  case "$stack" in
    node) stack_workflow=node-ci.yml ;;
    ui) stack_workflow=ui-ci.yml ;;
    helm) stack_workflow=helm-ci.yml ;;
    pulumi) stack_workflow=pulumi-ci.yml ;;
    actions|none) stack_workflow='' ;;
  esac
  {
    printf 'name: ci\non:\n  pull_request:\njobs:\n'
    if [ -n "$stack_workflow" ]; then
      printf '  ci:\n    uses: Verjson/.github/.github/workflows/%s@0123456789abcdef0123456789abcdef01234567\n' "$stack_workflow"
    fi
    if [ "$stack" = node ] || [ "$stack" = ui ] || [ "$stack" = helm ]; then
      printf '  generated-artifacts:\n    uses: Verjson/.github/.github/workflows/generated-artifacts.yml@0123456789abcdef0123456789abcdef01234567\n'
    fi
  } >"$tmp/workflow.yml"
  encode_workflow
  printf '[{"type":"file","path":".github/workflows/ci.yml"}]\n' >"$WORKFLOW_LIST_FILE"
}

encode_workflow() {
  jq -n --arg content "$(base64 -w0 "$tmp/workflow.yml")" '{content:$content}' >"$WORKFLOW_CONTENT_FILE"
}

stack() {
  jq -n --arg v "$1" '[{property_name:"verjson-stack", value:$v}]' >"$PROPS_FILE"
  workflow_for "$1"
}
no_stack() { printf '[]\n' >"$PROPS_FILE"; }
pulls() { jq -n --args '$ARGS.positional | map({merged_at:"2026-08-05T00:00:00Z", head:{sha:.}})' "$@" >"$PULLS_FILE"; }
# Named check runs, all concluded `success` unless a test overrides the file.
head_with() { local sha="$1"; shift; jq -n --args '{check_runs: ($ARGS.positional | map({name:., conclusion:"success"}))}' "$@" >"$CHECKDIR/$sha.json"; }

printf '[{"name":"alpha","archived":false}]\n' >"$REPOS_FILE"
workflow_for none

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
head_with s1 gate "ci / build-test" "ci / eligibility" "generated-artifacts / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" "generated-artifacts / validate"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a node repository emitting its full core set is conformant" \
  || { fail "a conformant node repository was not recognised ($rc)"; out | sed 's/^/diag - /'; }

# --- THE finding this exists for: a missing context is non-zero --------------
# `generated-artifacts / validate` is core for package repositories, and a repository not
# yet wired to the changelog contract emits nothing for it. Requiring it there
# is the permanently-pending wedge.
stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility"
head_with s2 gate "ci / build-test" "ci / eligibility"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'missing-core-contexts' "$tmp/out.txt" && grep -q 'generated-artifacts / validate' "$tmp/out.txt"; } \
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
                    {name:"generated-artifacts / validate",conclusion:"success"}]}' >"$CHECKDIR/s1.json"
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
head_with s1 gate "ci / lint-template" "generated-artifacts / validate"
head_with s2 gate "ci / lint-template" "generated-artifacts / validate"
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
{ [ "$rc" != "rc=0" ] && grep -q 'checks-unreadable' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "an unreadable check-runs API is reported, never counted as conformant" \
  || { fail "an unreadable check API was absorbed ($rc)"; out | sed 's/^/diag - /'; }

rc="$(STATUSES_FAIL=true run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'checks-unreadable' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a rate-limited status page is reported, never counted as conformant" \
  || { fail "a status pagination/rate failure was absorbed ($rc)"; out | sed 's/^/diag - /'; }

rc="$(PROPS_FAIL=true run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'properties-unreadable' "$tmp/out.txt"; } \
  && pass "an unreadable custom-property value fails closed" \
  || { fail "a property API failure was treated as classification ($rc)"; out | sed 's/^/diag - /'; }

rc="$(WORKFLOWS_FAIL=true run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-source-unreadable' "$tmp/out.txt"; } \
  && pass "unreadable workflow source fails closed" \
  || { fail "a workflow-source API failure was absorbed ($rc)"; out | sed 's/^/diag - /'; }

stack node
printf 'on: [unterminated\n' >"$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-source-unreadable' "$tmp/out.txt"; } \
  && pass "malformed workflow YAML fails closed" \
  || { fail "malformed caller source was accepted ($rc)"; out | sed 's/^/diag - /'; }

# --- a repository with no merged PRs is not conformant by default ------------
stack node; printf '[]\n' >"$PULLS_FILE"
rc="$(run_audit)"
{ grep -q 'no-merged-prs' "$tmp/out.txt" && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a repository with no merged PRs is reported, not silently conformant" \
  || { fail "an unaudited repository was counted as conformant ($rc)"; out | sed 's/^/diag - /'; }

# --- source contract: callers must be unconditional and canonically named ---
stack node; pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" "generated-artifacts / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" "generated-artifacts / validate"
sed -i '/^  pull_request:$/a\    paths:\n      - "src/**"' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-path-filter' "$tmp/out.txt"; } \
  && pass "a workflow-level paths filter is nonconformant even when sampled checks exist" \
  || { fail "a paths-filtered stack caller was called safe ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's#^on:$#on: {pull_request: {paths: ["src/**"]}}#; /^  pull_request:$/d' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-path-filter' "$tmp/out.txt"; } \
  && pass "an inline workflow-level paths filter is also nonconformant" \
  || { fail "an inline paths filter bypassed source inspection ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's/^  ci:$/  build:/' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'caller-job-name expected=ci actual=build' "$tmp/out.txt"; } \
  && pass "a thin stack caller with the wrong job name is nonconformant" \
  || { fail "a noncanonical stack caller name was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's/^  generated-artifacts:$/  generated-docs:/' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'caller-job-name expected=generated-artifacts actual=generated-docs' "$tmp/out.txt"; } \
  && pass "the generated-artifacts caller must publish generated-artifacts / validate" \
  || { fail "a noncanonical changelog caller name was accepted ($rc)"; out | sed 's/^/diag - /'; }

# --- repository enumeration is paginated, filters archives, and fails closed -
stack actions; pulls s1 s2
head_with s1 gate shell-tests
head_with s2 gate shell-tests
printf '[{"name":"alpha","archived":false},{"name":"retired","archived":true}]\n' >"$REPOS_FILE"
unset RCA_REPOS
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && ! grep -q 'repo=retired' "$tmp/out.txt"; } \
  && pass "paginated repository discovery excludes archived repositories" \
  || { fail "archived repository was audited or discovery failed ($rc)"; out | sed 's/^/diag - /'; }

rc="$(REPOS_FAIL=true run_audit)"
{ [ "$rc" = "rc=2" ] && grep -q 'phase=repository-list result=unreadable' "$tmp/out.txt"; } \
  && pass "repository pagination/rate failure is terminal" \
  || { fail "repository pagination failure produced a partial green audit ($rc)"; out | sed 's/^/diag - /'; }
export RCA_REPOS=alpha
printf '[{"name":"alpha","archived":false}]\n' >"$REPOS_FILE"

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi

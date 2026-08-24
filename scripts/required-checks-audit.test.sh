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
  .mode == "staged" and
  .mutation_authorized == true and
  .ruleset_plan.requested_enforcement == "active" and
  .ruleset_plan.human_gate_required == true and
  .ruleset_plan.rollout == {
    issue: 731,
    organization: "Verjson",
    ruleset_id: 20515817,
    ruleset_name: "core-checks-node",
    required_context: "changelog-contract",
    apply_acknowledgement: "apply-issue-731-core-checks-node",
    rollback_acknowledgement: "rollback-issue-731-core-checks-node"
  } and
  (has("universal_contexts") | not) and
  .stacks.node.contexts == ["ci / build-test", "ci / eligibility", "changelog-contract", "changelog / validate"] and
  .stacks.ui.contexts == ["ci / build-test", "changelog / validate"] and
  .stacks.helm.contexts == ["ci / lint-template", "changelog / validate"] and
  .caller_job_names.changelog == "changelog" and
  (.caller_job_names | has("generated_artifacts") | not) and
  .stacks.pulumi.contexts == ["ci / validate", "ci / preview"] and
  .stacks.actions.contexts == ["shell-tests"] and
  ([.ruleset_plan.rulesets[].name] | sort) == ([
    "changelog-contract-required", "core-checks-actions", "core-checks-helm",
    "core-checks-node", "core-checks-pulumi", "core-checks-ui"
  ] | sort) and
  (.ruleset_plan.rulesets[] | select(.name == "core-checks-node") | .contexts) ==
    ["ci / build-test", "ci / eligibility", "changelog-contract"] and
  (.ruleset_plan.rulesets[] | select(.name == "changelog-contract-required") | .contexts) ==
    ["changelog / validate"]
' "$contract" >/dev/null \
  && pass "declared contract pins every context and a human-gated staged rollout" \
  || fail "required-check declaration or staged rollout drifted"

mkdir -p "$tmp/bin" "$tmp/checks"
content_root="$tmp/content"
mkdir -p "$content_root/.github/workflows" "$content_root/scripts"
contract_pin="$(git -C "$here/.." rev-parse HEAD)"
generator="$here/gen-changelog-caller.sh"
bash "$generator" generated-artifacts "$contract_pin" >"$content_root/.github/workflows/changelog.yml"
bash "$generator" renderer "$contract_pin" >"$content_root/scripts/render-next.sh"
bash "$generator" contract-test "$contract_pin" >"$content_root/scripts/changelog-contract.test.sh"
bash "$generator" release-node "$contract_pin" >"$content_root/.github/workflows/release.yml"
mkdir -p "$tmp/artifact-baseline/.github/workflows" "$tmp/artifact-baseline/scripts"
cp "$content_root/.github/workflows/changelog.yml" "$tmp/artifact-baseline/.github/workflows/changelog.yml"
cp "$content_root/.github/workflows/release.yml" "$tmp/artifact-baseline/.github/workflows/release.yml"
cp "$content_root/scripts/render-next.sh" "$tmp/artifact-baseline/scripts/render-next.sh"
cp "$content_root/scripts/changelog-contract.test.sh" "$tmp/artifact-baseline/scripts/changelog-contract.test.sh"
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
  *"repos/Verjson/.github/contents/scripts/gen-changelog-caller.sh"*)
    printf 'fetch\n' >>"$GENERATOR_FETCHES"
    git -C "$REPO_ROOT" show "$CONTRACT_PIN:scripts/gen-changelog-caller.sh"; exit 0 ;;
  *"repos/Verjson/.github/compare/"*) printf '{"status":"%s"}\n' "${PIN_ANCESTRY_STATUS:-identical}" | { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }; exit 0 ;;
  *"repos/Verjson/.github/branches/main"*) printf '{"commit":{"sha":"%s"}}\n' "$CONTRACT_PIN" | { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }; exit 0 ;;
  *"repos/Verjson/.github"*) printf '{"default_branch":"main"}\n' | { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }; exit 0 ;;
  *"/contents/.github/workflows"|*"/contents/.github/workflows?ref="*)
    [ "${WORKFLOWS_FAIL:-false}" = true ] && exit 1
    emit "$WORKFLOW_LIST_FILE"; exit 0 ;;
  *"/contents/"*)
    [ "${WORKFLOWS_FAIL:-false}" = true ] && exit 1
    endpoint="${args[1]}"
    path="${endpoint#*contents/}"; path="${path%%\?*}"
    source="$CONTENT_ROOT/$path"
    [ -f "$source" ] || exit 1
    response="$STUB_TMP/content-response.json"
    jq -n --arg content "$(base64 -w0 "$source")" '{content:$content}' >"$response"
    emit "$response"; exit 0 ;;
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

cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  https://raw.githubusercontent.com/Verjson/.github/*/scripts/changelog.py)
    ref="${url#*Verjson/.github/}"; ref="${ref%%/*}"
    git -C "$REPO_ROOT" show "$ref:scripts/changelog.py" ;;
  https://raw.githubusercontent.com/Verjson/.github/*/scripts/gen-adr-index.sh)
    ref="${url#*Verjson/.github/}"; ref="${ref%%/*}"
    git -C "$REPO_ROOT" show "$ref:scripts/gen-adr-index.sh" ;;
  *) exit 1 ;;
esac
CURL
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH"
export CHECKDIR="$tmp/checks"
export PROPS_FILE="$tmp/props.json"
export PULLS_FILE="$tmp/pulls.json"
export REPOS_FILE="$tmp/repos.json"
export WORKFLOW_LIST_FILE="$tmp/workflows.json"
export WORKFLOW_CONTENT_FILE="$tmp/workflow-content.json"
export CONTENT_ROOT="$content_root"
export CONTRACT_PIN="$contract_pin"
export GENERATOR_FETCHES="$tmp/generator-fetches.log"
export REPO_ROOT="$here/.."
export STUB_TMP="$tmp"
export RCA_ORG=Verjson
export RCA_SAMPLE_PRS=2
export RCA_REPOS=alpha
: >"$GENERATOR_FETCHES"

workflow_for() {
  local stack="$1" stack_workflow=''
  cp "$tmp/artifact-baseline/.github/workflows/changelog.yml" "$content_root/.github/workflows/changelog.yml"
  cp "$tmp/artifact-baseline/.github/workflows/release.yml" "$content_root/.github/workflows/release.yml"
  cp "$tmp/artifact-baseline/scripts/render-next.sh" "$content_root/scripts/render-next.sh"
  cp "$tmp/artifact-baseline/scripts/changelog-contract.test.sh" "$content_root/scripts/changelog-contract.test.sh"
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
    if [ "$stack" = node ]; then
      printf '  changelog-contract:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          persist-credentials: false\n      - run: echo "VERJSON_CHANGELOG_TOOL_CACHE=$RUNNER_TEMP/verjson-changelog-tools" >> "$GITHUB_ENV"\n      - run: bash scripts/changelog-contract.test.sh\n'
    fi
  } >"$tmp/workflow.yml"
  encode_workflow
  printf '[{"type":"file","path":".github/workflows/ci.yml"},{"type":"file","path":".github/workflows/changelog.yml"},{"type":"file","path":".github/workflows/release.yml"}]\n' >"$WORKFLOW_LIST_FILE"
}

encode_workflow() {
  cp "$tmp/workflow.yml" "$content_root/.github/workflows/ci.yml"
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
head_with s1 "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
head_with s2 "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a node repository emitting its full core set is conformant" \
  || { fail "a conformant node repository was not recognised ($rc)"; out | sed 's/^/diag - /'; }

mkdir -p "$tmp/hostile-python"
printf 'raise SystemExit("ambient yaml module executed")\n' >"$tmp/hostile-python/yaml.py"
rc="$(PYTHONPATH="$tmp/hostile-python" run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "workflow inspection ignores ambient Python packages" \
  || { fail "an ambient Python package changed audit behavior ($rc)"; out | sed 's/^/diag - /'; }

sed -i '1i---' "$content_root/.github/workflows/ci.yml"
printf '\n...\n' >>"$content_root/.github/workflows/ci.yml"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "valid YAML document markers do not fault workflow inspection" \
  || { fail "YAML document markers changed audit behavior ($rc)"; out | sed 's/^/diag - /'; }

cp "$content_root/.github/workflows/ci.yml" "$tmp/canonical-ci.yml"
for unsupported_yaml in \
  'jobs: &shared-jobs' \
  '  <<: *shared-job' \
  'on: !canonical pull_request' \
  'on: ! {pull_request: {}}' \
  'jobs: {base: &base {runs-on: ubuntu-24.04}, copy: *base}' \
  'jobs: {base: !<tag:example.com,2026:job> {runs-on: ubuntu-24.04}}' \
  'jobs: {base: &base !canonical {runs-on: ubuntu-24.04}}'; do
  cp "$tmp/canonical-ci.yml" "$content_root/.github/workflows/ci.yml"
  printf '\n%s\n' "$unsupported_yaml" >>"$content_root/.github/workflows/ci.yml"
  rc="$(run_audit)"
  { [ "$rc" != "rc=0" ] && ! grep -q 'result=conformant' "$tmp/out.txt"; } \
    && pass "unsupported YAML syntax fails workflow inspection closed: $unsupported_yaml" \
    || { fail "unsupported YAML syntax was accepted: $unsupported_yaml ($rc)"; out | sed 's/^/diag - /'; }
done
cp "$tmp/canonical-ci.yml" "$content_root/.github/workflows/ci.yml"

block_scalar_result="$tmp/block-scalar-result.json"
printf '%s\n' \
  'jobs:' \
  '  example:' \
  '    if: ${{ !cancelled() }}' \
  '    steps:' \
  '      - run: |' \
  '          echo result: !important' \
  | python3 -I "$here/required-checks-workflow.py" changelog >"$block_scalar_result"
rc=$?
{ [ "$rc" -eq 0 ] && jq -e '.changelog_contract == "absent"' "$block_scalar_result" >/dev/null; } \
  && pass "YAML-like shell text inside a block scalar remains supported content" \
  || fail "block scalar shell content was mistaken for unsupported YAML syntax (rc=$rc)"

rc="$(RCA_WORKFLOW_INSPECTOR="$tmp/missing-workflow-inspector.py" run_audit)"
{ [ "$rc" = "rc=2" ] && grep -q 'workflow-inspector-missing' "$tmp/out.txt"; } \
  && pass "a missing hermetic workflow inspector fails at startup" \
  || { fail "the audit ran without its workflow inspector ($rc)"; out | sed 's/^/diag - /'; }

stack node; pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
"$generator" workflow "$contract_pin" >"$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "the documented workflow compatibility mode remains conformant" \
  || { fail "workflow compatibility mode failed provenance ($rc)"; out | sed 's/^/diag - /'; }

# The documented single-caller layout is one .github/workflows/changelog.yml
# generated at the shared pin. Exercise every package stack through the full
# source audit so the fixture cannot drift back to the retired file path.
for documented_stack in node ui helm; do
  stack "$documented_stack"; pulls s1 s2
  case "$documented_stack" in
    node)
      head_with s1 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
      head_with s2 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
      ;;
    ui)
      head_with s1 gate "ci / build-test" "changelog / validate"
      head_with s2 gate "ci / build-test" "changelog / validate"
      ;;
    helm)
      head_with s1 gate "ci / lint-template" "changelog / validate"
      head_with s2 gate "ci / lint-template" "changelog / validate"
      ;;
  esac
  rc="$(run_audit)"
  { [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
    && pass "the documented $documented_stack changelog.yml layout is conformant" \
    || { fail "the documented $documented_stack layout was rejected ($rc)"; out | sed 's/^/diag - /'; }
done

# --- THE finding this exists for: a missing context is non-zero --------------
# A generated release contract can drift independently of fragment validation.
# Requiring only `changelog / validate` leaves the caller, renderer,
# contract test, and release caller free to disagree about their immutable pin.
stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" "changelog / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" "changelog / validate"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'missing-core-contexts' "$tmp/out.txt" && grep -q 'missing=changelog-contract;' "$tmp/out.txt"; } \
  && pass "a node repository omitting generated contract conformance is nonconformant" \
  || { fail "an absent changelog-contract context was not reported ($rc)"; out | sed 's/^/diag - /'; }

# `changelog / validate` is core for package repositories, and a repository not
# yet wired to the changelog contract emits nothing for it. Requiring it there
# is the permanently-pending wedge.
stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" changelog-contract
head_with s2 gate "ci / build-test" "ci / eligibility" changelog-contract
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
                    {name:"changelog-contract",conclusion:"success"},
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

# --- authorization-arm contexts are independent -----------------------------
stack actions
pulls s1 s2
head_with s1 "shell-tests"
head_with s2 "shell-tests"
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && ! grep -q 'missing=gate' "$tmp/out.txt" && ! grep -q 'missing=arm' "$tmp/out.txt"; } \
  && pass "authorization-arm contexts are not conflated with deterministic stack checks" \
  || { fail "authorization-arm context leaked into the stack contract ($rc)"; out | sed 's/^/diag - /'; }

# --- commit statuses count -----------------------------------------------------
# The audit reads check-runs AND statuses; a context delivered as a commit status
# must not be reported missing just because it is not a check run.
stack actions
pulls s1 s2
head_with s1
head_with s2
printf '{"statuses":[{"context":"shell-tests","state":"success"}]}\n' >"$CHECKDIR/s1.status.json"
printf '{"statuses":[{"context":"shell-tests","state":"success"}]}\n' >"$CHECKDIR/s2.status.json"
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
head_with s1 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
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
sed -i 's/^  changelog:$/  generated-docs:/' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "the generated-artifacts caller must publish changelog / validate" \
  || { fail "a noncanonical changelog caller name was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
sed -i '/^  changelog:$/a\    name: renamed required check' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "a job-level name cannot disguise a changed changelog context" \
  || { fail "a named changelog caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
sed -i '/^  changelog:$/a\    strategy:\n      matrix:\n        shard: [one, two]' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "a matrix cannot suffix the generated changelog context" \
  || { fail "a matrixed changelog caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
sed -i 's/^      changelog: true$/      changelog: false/' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "the source audit requires changelog validation to be enabled" \
  || { fail "a changelog-disabled generated caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
sed -i 's|^    uses: Verjson/|    # uses: Verjson/|' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-missing' "$tmp/out.txt"; } \
  && pass "a commented uses lookalike cannot satisfy source inspection" \
  || { fail "a comment-only generated caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
cp "$content_root/.github/workflows/changelog.yml" "$content_root/.github/workflows/generated-artifacts.yml"
printf '[{"type":"file","path":".github/workflows/ci.yml"},{"type":"file","path":".github/workflows/changelog.yml"},{"type":"file","path":".github/workflows/generated-artifacts.yml"},{"type":"file","path":".github/workflows/release.yml"}]\n' >"$WORKFLOW_LIST_FILE"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-missing expected=1 actual=2' "$tmp/out.txt"; } \
  && pass "duplicate generated changelog callers fail as ambiguous" \
  || { fail "duplicate caller files were accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
cat >"$content_root/.github/workflows/alternate-indentation.yml" <<YAML
name: alternate indentation
on: pull_request
jobs:
    changelog:
        uses: Verjson/.github/.github/workflows/generated-artifacts.yml@$contract_pin
        with:
            changelog: true
            contract_ref: $contract_pin
YAML
printf '[{"type":"file","path":".github/workflows/alternate-indentation.yml"},{"type":"file","path":".github/workflows/ci.yml"},{"type":"file","path":".github/workflows/changelog.yml"},{"type":"file","path":".github/workflows/release.yml"}]\n' >"$WORKFLOW_LIST_FILE"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-missing expected=1 actual=2' "$tmp/out.txt"; } \
  && pass "alternate YAML indentation cannot hide a duplicate caller" \
  || { fail "an alternately indented duplicate caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
cp "$content_root/.github/workflows/changelog.yml" "$content_root/.github/workflows/docs-validation.yml"
printf '[{"type":"file","path":".github/workflows/ci.yml"},{"type":"file","path":".github/workflows/changelog.yml"},{"type":"file","path":".github/workflows/docs-validation.yml"},{"type":"file","path":".github/workflows/release.yml"}]\n' >"$WORKFLOW_LIST_FILE"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-missing expected=1 actual=2' "$tmp/out.txt"; } \
  && pass "a renamed duplicate generated caller fails as ambiguous" \
  || { fail "a renamed duplicate caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
cat >"$content_root/.github/workflows/legacy-validation.yml" <<YAML
name: legacy validation
on:
  pull_request:
jobs:
  legacy:
    uses: Verjson/.github/.github/workflows/changelog-validate.yml@$contract_pin
    with:
      contract_ref: $contract_pin
YAML
printf '[{"type":"file","path":".github/workflows/ci.yml"},{"type":"file","path":".github/workflows/changelog.yml"},{"type":"file","path":".github/workflows/legacy-validation.yml"},{"type":"file","path":".github/workflows/release.yml"}]\n' >"$WORKFLOW_LIST_FILE"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid path=.github/workflows/legacy-validation.yml' "$tmp/out.txt"; } \
  && pass "a legacy changelog-validate caller cannot coexist with the canonical caller" \
  || { fail "an additional legacy caller was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
sed -i '/^      contract_ref:/a\      unexpected_input: true' "$content_root/.github/workflows/changelog.yml"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "the generated caller rejects additional nested inputs" \
  || { fail "an additional generated caller input was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack helm; pulls s1 s2
head_with s1 gate "ci / lint-template" "changelog / validate"
head_with s2 gate "ci / lint-template" "changelog / validate"
cat >>"$content_root/.github/workflows/changelog.yml" <<YAML
  duplicate-changelog:
    uses: Verjson/.github/.github/workflows/generated-artifacts.yml@$contract_pin
    with:
      changelog: true
      contract_ref: $contract_pin
YAML
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-caller-invalid' "$tmp/out.txt"; } \
  && pass "multiple generated changelog jobs in one workflow fail as ambiguous" \
  || { fail "ambiguous caller jobs were accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
unmerged_pin=ffffffffffffffffffffffffffffffffffffffff
for artifact in \
  "$content_root/.github/workflows/changelog.yml" \
  "$content_root/.github/workflows/release.yml" \
  "$content_root/scripts/render-next.sh" \
  "$content_root/scripts/changelog-contract.test.sh"; do
  sed -i "s/$contract_pin/$unmerged_pin/g" "$artifact"
done
: >"$GENERATOR_FETCHES"
export PIN_ANCESTRY_STATUS=diverged
rc="$(run_audit)"
unset PIN_ANCESTRY_STATUS
{ [ "$rc" != "rc=0" ] && grep -q 'generated-contract-pin-not-on-default' "$tmp/out.txt" && [ ! -s "$GENERATOR_FETCHES" ]; } \
  && pass "an unmerged consumer-selected generator pin is rejected before fetch or execution" \
  || { fail "an unmerged generator pin reached trusted execution ($rc)"; out | sed 's/^/diag - /'; }

stack node
printf '\n# handwritten drift\n' >>"$content_root/scripts/render-next.sh"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'generated-contract-byte-drift artifact=render-next.sh' "$tmp/out.txt"; } \
  && pass "a handwritten renderer lookalike cannot satisfy generated provenance" \
  || { fail "renderer byte drift was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
printf '#!/usr/bin/env bash\nexit 0\n' >"$content_root/scripts/changelog-contract.test.sh"
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -qE 'generated-contract-(parameters-invalid|byte-drift)' "$tmp/out.txt"; } \
  && pass "a trivial replacement contract test cannot satisfy generated provenance" \
  || { fail "a trivial generated-test escape was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
pulls s1 s2
head_with s1 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
head_with s2 gate "ci / build-test" "ci / eligibility" changelog-contract "changelog / validate"
sed -i 's/^    runs-on: ubuntu-24.04$/    runs-on:\n      - self-hosted\n      - linux/' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" = "rc=0" ] && grep -q 'result=conformant' "$tmp/out.txt"; } \
  && pass "a block-sequence runner label remains conformant" \
  || { fail "a valid block-sequence runs-on was rejected ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's/^  changelog-contract:$/  contract-conformance:/' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-count expected=1 actual=0' "$tmp/out.txt"; } \
  && pass "the current workflow source must publish the literal changelog-contract job" \
  || { fail "a renamed changelog-contract job was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^  changelog-contract:$/a\    if: false' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "a conditional changelog-contract job cannot satisfy the source contract" \
  || { fail "a conditional changelog-contract job was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^  changelog-contract:$/a\    name: harmless-looking-name' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "a display name cannot replace the literal required context" \
  || { fail "a renamed check context was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^  changelog-contract:$/a\    strategy:\n      matrix:\n        shard: [1, 2]' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "a matrix cannot suffix the literal required context" \
  || { fail "a matrix check-name escape was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^  changelog-contract:$/a\    continue-on-error: true' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "continue-on-error cannot make contract failures advisory" \
  || { fail "continue-on-error was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^          persist-credentials: false$/a\          ref: main' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "the contract job cannot test a substituted checkout ref" \
  || { fail "a default-branch checkout escape was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^          persist-credentials: false$/a\          repository: attacker/lookalike' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "the contract job cannot substitute another repository" \
  || { fail "a repository checkout escape was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's#bash scripts/changelog-contract.test.sh#bash scripts/other.test.sh#' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'changelog-contract-job-invalid' "$tmp/out.txt"; } \
  && pass "the required job must execute the generated changelog contract test" \
  || { fail "a changelog-contract job that runs another command was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i 's/^  pull_request:$/  workflow_dispatch:/' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-trigger-missing' "$tmp/out.txt"; } \
  && pass "the required job must run for pull requests" \
  || { fail "a non-PR changelog-contract job was accepted ($rc)"; out | sed 's/^/diag - /'; }

stack node
sed -i '/^  pull_request:$/a\    types: [opened]' "$tmp/workflow.yml"
encode_workflow
rc="$(run_audit)"
{ [ "$rc" != "rc=0" ] && grep -q 'workflow-trigger-missing' "$tmp/out.txt"; } \
  && pass "pull-request type filters cannot omit synchronize events" \
  || { fail "a type-filtered pull_request trigger was accepted ($rc)"; out | sed 's/^/diag - /'; }

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

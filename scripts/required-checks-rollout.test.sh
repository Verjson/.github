#!/usr/bin/env bash
# shellcheck disable=SC2015  # Compact assertions intentionally use A && pass || fail.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/required-checks-rollout.sh"
contract="$here/../.github/required-check-contract.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

bundle="$tmp/bundle"
remote_bundle="$tmp/remote-bundle"
mkdir -p "$tmp/bin" "$bundle/scripts" "$bundle/.github" "$remote_bundle/scripts" "$remote_bundle/.github"
cp "$script" "$bundle/scripts/required-checks-rollout.sh"
cp "$contract" "$bundle/.github/required-check-contract.json"
cp "$bundle/scripts/required-checks-rollout.sh" "$remote_bundle/scripts/required-checks-rollout.sh"
cp "$bundle/.github/required-check-contract.json" "$remote_bundle/.github/required-check-contract.json"

cat >"$bundle/scripts/required-checks-audit.sh" <<'AUDIT'
#!/usr/bin/env bash
printf '%s\n' "$RCA_REPOS" >"$AUDITED_REPOS"
cp "$RCA_HEADS_FILE" "$AUDITED_HEADS"
[ "${AUDIT_FAIL:-false}" != true ]
AUDIT
chmod +x "$bundle/scripts/required-checks-audit.sh"
cp "$bundle/scripts/required-checks-audit.sh" "$remote_bundle/scripts/required-checks-audit.sh"
git -C "$bundle" init -q

cat >"$tmp/live-baseline.json" <<'JSON'
{
  "id": 20515817,
  "name": "core-checks-node",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [{"actor_type":"OrganizationAdmin","actor_id":null,"bypass_mode":"always"}],
  "conditions": {
    "ref_name": {"include":["~DEFAULT_BRANCH"],"exclude":[]},
    "repository_property": {"include":[
      {"name":"verjson-stack","property_values":["node"],"source":"custom"},
      {"name":"verjson-core-checks","property_values":["enforced"],"source":"custom"}
    ],"exclude":[]}
  },
  "rules": [
    {"type":"deletion"},
    {"type":"required_status_checks","parameters":{
      "strict_required_status_checks_policy":false,
      "do_not_enforce_on_create":true,
      "required_status_checks":[{"context":"ci / build-test","integration_id":15368},{"context":"ci / eligibility"}]
    }}
  ]
}
JSON
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) += [{"context":"changelog-contract"}]' \
  "$tmp/live-baseline.json" >"$tmp/updated.json"
jq '.enforcement = "disabled"' "$tmp/live-baseline.json" >"$tmp/ruleset-drift.json"
jq '.rules += [.rules[] | select(.type == "required_status_checks")]' \
  "$tmp/live-baseline.json" >"$tmp/multiple-status-rules.json"

cat >"$tmp/properties.json" <<'JSON'
[
  {"repository_full_name":"Verjson/alpha","properties":[
    {"property_name":"verjson-stack","value":"node"},
    {"property_name":"verjson-core-checks","value":"enforced"}
  ]},
  {"repository_full_name":"Verjson/beta","properties":[
    {"property_name":"verjson-core-checks","value":"enforced"},
    {"property_name":"verjson-stack","value":"node"}
  ]},
  {"repository_full_name":"Verjson/exempt","properties":[
    {"property_name":"verjson-stack","value":"node"},
    {"property_name":"verjson-core-checks","value":"exempt"}
  ]}
]
JSON
jq 'map(select(.repository_full_name != "Verjson/beta"))' "$tmp/properties.json" >"$tmp/properties-drift.json"

cat >"$tmp/effective.json" <<'JSON'
[
  {"ruleset_id":20515817,"ruleset_source_type":"Organization","type":"required_status_checks",
    "parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":true,
      "required_status_checks":[{"context":"ci / build-test","integration_id":15368},{"context":"ci / eligibility"},{"context":"changelog-contract"}]}}
]
JSON
printf '[]\n' >"$tmp/effective-mismatch.json"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
count() { local file="$1" n=0; [ ! -f "$file" ] || n="$(cat "$file")"; n=$((n + 1)); printf '%s\n' "$n" >"$file"; printf '%s' "$n"; }
case "$*" in
  *"--method PUT"*)
    printf '%s\n' "$*" >>"$MUTATIONS"
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--input" ] && cp "${args[$((i + 1))]}" "$PUT_PAYLOAD"
    done
    cp "$UPDATED_RULESET" "$LIVE_RULESET"; exit 0 ;;
  *"orgs/Verjson/rulesets/20515817"*)
    n="$(count "$RULESET_READS")"
    if [ "${RULESET_DRIFT_ON_REREAD:-false}" = true ] && [ "$n" -eq 2 ]; then cat "$RULESET_DRIFT"; else cat "$LIVE_RULESET"; fi ;;
  *"orgs/Verjson/properties/values"*)
    n="$(count "$PROPERTY_READS")"
    if [ -n "${PROPERTY_DRIFT_AT:-}" ] && [ "$n" -eq "$PROPERTY_DRIFT_AT" ]; then cat "$PROPERTY_DRIFT"; else cat "$PROPERTY_VALUES"; fi ;;
  *"repos/Verjson/.github/contents/"*)
    endpoint="${2#*contents/}"; path="${endpoint%%\?*}"
    cat "$REMOTE_BUNDLE/$path" ;;
  *"repos/Verjson/.github") printf '{"default_branch":"main"}\n' ;;
  *"repos/Verjson/alpha/branches/main"*)
    n="$(count "$BRANCH_READS")"; sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [ -z "${HEAD_DRIFT_AT:-}" ] || [ "$n" -ne "$HEAD_DRIFT_AT" ] || sha=cccccccccccccccccccccccccccccccccccccccc
    printf '{"commit":{"sha":"%s"}}\n' "$sha" ;;
  *"repos/Verjson/beta/branches/main"*)
    n="$(count "$BRANCH_READS")"; sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    [ -z "${HEAD_DRIFT_AT:-}" ] || [ "$n" -ne "$HEAD_DRIFT_AT" ] || sha=dddddddddddddddddddddddddddddddddddddddd
    printf '{"commit":{"sha":"%s"}}\n' "$sha" ;;
  *"repos/Verjson/alpha"|*"repos/Verjson/beta") printf '{"default_branch":"main"}\n' ;;
  *"/rules/branches/main"*)
    if [ "${EFFECTIVE_MISMATCH:-false}" = true ]; then cat "$EFFECTIVE_MISMATCH_FILE"; else cat "$EFFECTIVE_RULES"; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
GH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH"
export LIVE_RULESET="$tmp/live.json" UPDATED_RULESET="$tmp/updated.json" RULESET_DRIFT="$tmp/ruleset-drift.json"
export PROPERTY_VALUES="$tmp/properties.json" PROPERTY_DRIFT="$tmp/properties-drift.json"
export EFFECTIVE_RULES="$tmp/effective.json" EFFECTIVE_MISMATCH_FILE="$tmp/effective-mismatch.json"
export MUTATIONS="$tmp/mutations.log" PUT_PAYLOAD="$tmp/put-payload.json"
export AUDITED_REPOS="$tmp/audited-repos.txt" AUDITED_HEADS="$tmp/audited-heads.tsv"
export RULESET_READS="$tmp/ruleset-reads" PROPERTY_READS="$tmp/property-reads" BRANCH_READS="$tmp/branch-reads"
export REMOTE_BUNDLE="$remote_bundle"

reset_fixture() {
  cp "$tmp/live-baseline.json" "$LIVE_RULESET"
  : >"$MUTATIONS"
  : >"$RULESET_READS"; : >"$PROPERTY_READS"; : >"$BRANCH_READS"
  unset AUDIT_FAIL PROPERTY_DRIFT_AT HEAD_DRIFT_AT RULESET_DRIFT_ON_REREAD EFFECTIVE_MISMATCH
}
run_readonly() {
  ( printf '{"hostile":"stdin"}\n' | RCA_ORG=Verjson RCA_APPLY=false RCA_CONTRACT_FILE="$contract" RCA_AUDIT_SCRIPT="$bundle/scripts/required-checks-audit.sh" "$script" >"$tmp/out.txt" 2>&1; echo "rc=$?" )
}
run_apply() {
  ( printf '{"hostile":"stdin"}\n' | env -u RCA_CONTRACT_FILE -u RCA_AUDIT_SCRIPT -u RCA_DEFAULT_BRANCH \
      RCA_ORG=Verjson RCA_APPLY=true RCA_ACK=apply-issue-731-core-checks-node \
      "$bundle/scripts/required-checks-rollout.sh" >"$tmp/out.txt" 2>&1; echo "rc=$?" )
}

reset_fixture
rc="$(run_readonly)"
{ [ "$rc" = "rc=0" ] && [ "$(cat "$AUDITED_REPOS")" = "alpha beta" ] && \
  grep -q $'alpha\tmain\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$AUDITED_HEADS" && [ ! -s "$MUTATIONS" ]; } \
  && pass "read-only staging audits the exact live property-selected heads" \
  || fail "read-only staging did not preserve selected state ($rc)"

reset_fixture
rc="$(RCA_APPLY=true RCA_ACK=apply-issue-731-core-checks-node RCA_ORG=Verjson RCA_CONTRACT_FILE="$contract" RCA_AUDIT_SCRIPT="$bundle/scripts/required-checks-audit.sh" "$script" 2>&1; echo "rc=$?")"
{ [[ "$rc" == *"rc=2"* ]] && [[ "$rc" == *"apply-override-forbidden"* ]] && [ ! -s "$MUTATIONS" ]; } \
  && pass "apply mode rejects contract and audit path overrides before conformance" \
  || fail "an apply override reached the gated path"

reset_fixture
export AUDIT_FAIL=true
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'selected-repositories-nonconformant' "$tmp/out.txt"; } \
  && pass "a nonconforming governed repository makes mutation impossible" \
  || fail "failed conformance did not stop mutation ($rc)"

reset_fixture
printf '\n# remote drift\n' >>"$remote_bundle/scripts/required-checks-audit.sh"
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'canonical-file-not-on-default' "$tmp/out.txt"; } \
  && pass "apply binds the canonical audit and rollout implementation to merged bytes" \
  || fail "unmerged canonical code reached conformance or mutation ($rc)"
cp "$bundle/scripts/required-checks-audit.sh" "$remote_bundle/scripts/required-checks-audit.sh"

reset_fixture
export HEAD_DRIFT_AT=3
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'governed-state-changed-during-audit' "$tmp/out.txt"; } \
  && pass "a selected default-branch head change closes the audit-to-write race" \
  || fail "head TOCTOU reached mutation ($rc)"

reset_fixture
export PROPERTY_DRIFT_AT=2
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'governed-state-changed-during-audit' "$tmp/out.txt"; } \
  && pass "a property-selected repository change closes the audit-to-write race" \
  || fail "property TOCTOU reached mutation ($rc)"

reset_fixture
export RULESET_DRIFT_ON_REREAD=true
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'ruleset-changed-during-audit' "$tmp/out.txt"; } \
  && pass "full mutable ruleset drift blocks the intended delta" \
  || fail "ruleset preimage drift reached mutation ($rc)"

reset_fixture
cp "$tmp/multiple-status-rules.json" "$LIVE_RULESET"
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ ! -s "$MUTATIONS" ] && grep -q 'live-ruleset-shape-drift' "$tmp/out.txt"; } \
  && pass "multiple status-check rules cannot broaden the intended delta" \
  || fail "an ambiguous status-check delta reached mutation ($rc)"

reset_fixture
rc="$(run_apply)"
recovery_file="$(find "$bundle/.git/ruleset-recovery" -type f -name '*.json' | sort | tail -1)"
{ [ "$rc" = "rc=0" ] && [ -s "$MUTATIONS" ] && grep -q 'applied-and-verified' "$tmp/out.txt" && \
  [ "$(stat -c %a "$recovery_file")" = 600 ] && \
  jq -e '(.preimage.rules | any(.type == "deletion")) and (.intended.bypass_actors == .preimage.bypass_actors)' "$recovery_file" >/dev/null && \
  jq -e '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] == [
    {"context":"ci / build-test","integration_id":15368},{"context":"ci / eligibility"},{"context":"changelog-contract"}
  ] and (.rules | any(.type == "deletion"))' "$PUT_PAYLOAD" >/dev/null; } \
  && pass "a valid apply preserves the full preimage, integration binding, and protected recovery artifact" \
  || { fail "a valid staged rollout did not complete ($rc)"; sed 's/^/diag - /' "$tmp/out.txt"; }

reset_fixture
export EFFECTIVE_MISMATCH=true
rc="$(run_apply)"
{ [ "$rc" = "rc=2" ] && [ -s "$MUTATIONS" ] && grep -q 'effective-rule-mismatch.*recovery_file=' "$tmp/out.txt"; } \
  && pass "post-write verification failures report the retained exact recovery artifact" \
  || fail "post-write failure did not retain/report recovery ($rc)"

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi

#!/usr/bin/env bash
# Stage one declared organization ruleset update behind live-scope discovery,
# read-only conformance, a merged-contract check, and an explicit human gate.
set -euo pipefail

fault() { echo "::error::phase=$1 result=$2 ${3:-}" >&2; exit 2; }

for tool in gh jq cmp mktemp sed tr wc readlink date cut sort git mkdir chmod; do
  command -v "$tool" >/dev/null 2>&1 ||
    fault startup toolchain-missing "tool=$tool"
done

ORG="${RCA_ORG:?RCA_ORG must name the organization}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
contract_override_set="${RCA_CONTRACT_FILE+x}"
audit_override_set="${RCA_AUDIT_SCRIPT+x}"
inspector_override_set="${RCA_WORKFLOW_INSPECTOR+x}"
branch_override_set="${RCA_DEFAULT_BRANCH+x}"
CONTRACT_FILE="${RCA_CONTRACT_FILE:-$script_dir/../.github/required-check-contract.json}"
AUDIT_SCRIPT="${RCA_AUDIT_SCRIPT:-$script_dir/required-checks-audit.sh}"
APPLY="${RCA_APPLY:-false}"
ACK="${RCA_ACK:-}"

[ -f "$AUDIT_SCRIPT" ] || fault startup audit-unavailable "path=$AUDIT_SCRIPT"
case "$APPLY" in true|false) ;; *) fault startup apply-unparseable "RCA_APPLY=$APPLY" ;; esac

jq -e '
  .schema_version == 1 and
  .mode == "staged" and
  .mutation_authorized == true and
  .ruleset_plan.requested_enforcement == "active" and
  .ruleset_plan.human_gate_required == true and
  (.ruleset_plan.rollout.issue | type == "number") and
  (.ruleset_plan.rollout.organization | type == "string" and length > 0) and
  (.ruleset_plan.rollout.ruleset_id | type == "number") and
  (.ruleset_plan.rollout.ruleset_name | type == "string" and length > 0) and
  (.ruleset_plan.rollout.required_context | type == "string" and length > 0) and
  (.ruleset_plan.rollout.apply_acknowledgement | type == "string" and length > 0) and
  (.ruleset_plan.rollout.rollback_acknowledgement | type == "string" and length > 0)
' "$CONTRACT_FILE" >/dev/null 2>&1 || fault contract declaration-invalid "file=$CONTRACT_FILE"

ruleset_id="$(jq -r '.ruleset_plan.rollout.ruleset_id' "$CONTRACT_FILE")"
ruleset_name="$(jq -r '.ruleset_plan.rollout.ruleset_name' "$CONTRACT_FILE")"
required_context="$(jq -r '.ruleset_plan.rollout.required_context' "$CONTRACT_FILE")"
expected_ack="$(jq -r '.ruleset_plan.rollout.apply_acknowledgement' "$CONTRACT_FILE")"
expected_org="$(jq -r '.ruleset_plan.rollout.organization' "$CONTRACT_FILE")"
[ "$ORG" = "$expected_org" ] || fault authorization organization-mismatch "expected=$expected_org actual=$ORG"

if [ "$APPLY" = true ]; then
  [ -z "$contract_override_set" ] && [ -z "$audit_override_set" ] && \
    [ -z "$inspector_override_set" ] && [ -z "$branch_override_set" ] ||
    fault authorization apply-override-forbidden "RCA_CONTRACT_FILE, RCA_AUDIT_SCRIPT, RCA_WORKFLOW_INSPECTOR, and RCA_DEFAULT_BRANCH are read-only test overrides"
fi

planned="$(jq -c --arg name "$ruleset_name" '.ruleset_plan.rulesets[] | select(.name == $name)' "$CONTRACT_FILE")"
[ -n "$planned" ] || fault contract rollout-ruleset-missing "name=$ruleset_name"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$APPLY" = true ]; then
  default_branch="$(gh api "repos/$ORG/.github" 2>/dev/null | jq -er .default_branch)" ||
    fault authorization default-branch-unreadable "repo=$ORG/.github"
  for binding in \
    ".github/required-check-contract.json:$CONTRACT_FILE" \
    "scripts/required-checks-audit.sh:$AUDIT_SCRIPT" \
    "scripts/required-checks-workflow.py:$script_dir/required-checks-workflow.py" \
    "scripts/required-checks-rollout.sh:$(readlink -f "$0")"; do
    remote_path="${binding%%:*}"
    local_path="${binding#*:}"
    remote_file="$tmp/remote-${remote_path//\//-}"
    gh api "repos/$ORG/.github/contents/$remote_path?ref=$default_branch" \
      -H 'Accept: application/vnd.github.raw+json' >"$remote_file" 2>/dev/null ||
      fault authorization canonical-file-unreadable "path=$remote_path branch=$default_branch"
    cmp -s "$local_path" "$remote_file" ||
      fault authorization canonical-file-not-on-default "path=$remote_path branch=$default_branch"
  done
fi

live="$(gh api "orgs/$ORG/rulesets/$ruleset_id" 2>/dev/null)" ||
  fault discovery ruleset-unreadable "id=$ruleset_id"

jq -e --arg name "$ruleset_name" '
  .name == $name and .target == "branch" and .enforcement == "active" and
  .conditions.ref_name.include == ["~DEFAULT_BRANCH"] and
  .conditions.ref_name.exclude == [] and
  .conditions.repository_property.exclude == [] and
  all(.conditions.repository_property.include[]; .source == "custom") and
  ([.rules[] | select(.type == "required_status_checks")] | length) == 1
' <<<"$live" >/dev/null 2>&1 ||
  fault discovery live-ruleset-shape-drift "id=$ruleset_id name=$ruleset_name"

planned_properties="$(jq -c '.repository_properties | sort_by(.name)' <<<"$planned")"
live_properties="$(jq -c '[.conditions.repository_property.include[] | {name, values: .property_values}] | sort_by(.name)' <<<"$live")"
[ "$planned_properties" = "$live_properties" ] ||
  fault discovery live-ruleset-scope-drift "id=$ruleset_id"

planned_contexts="$(jq -c '.contexts' <<<"$planned")"
live_contexts="$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' <<<"$live")"
jq -ne --arg required "$required_context" --argjson planned "$planned_contexts" --argjson current "$live_contexts" '
  ($planned | index($required)) != null and
  ($current - $planned | length) == 0 and
  (($planned - $current) | all(. == $required))
' >/dev/null 2>&1 ||
  fault discovery live-context-drift "id=$ruleset_id planned=$planned_contexts current=$live_contexts required=$required_context"

discover_selected_state() { # stdout = repo<TAB>default-branch<TAB>head, sorted
  local property_values repositories repo metadata branch encoded_branch sha
  property_values="$(gh api --paginate "orgs/$ORG/properties/values?per_page=100" 2>/dev/null | jq -s '[.[][]]')" ||
    fault discovery properties-unreadable "org=$ORG"
  repositories="$(jq -r --argjson wanted "$planned_properties" '
    .[] |
    select(. as $repo | $wanted | all(. as $want |
      $repo.properties | any(
        .property_name == $want.name and
        (.value as $actual | $want.values | index($actual))
      )
    )) |
    .repository_full_name | split("/")[-1]
  ' <<<"$property_values")"
  [ -n "$repositories" ] || fault discovery governed-set-empty "ruleset=$ruleset_name"
  while read -r repo; do
    [ -n "$repo" ] || continue
    metadata="$(gh api "repos/$ORG/$repo" 2>/dev/null)" ||
      fault discovery repository-unreadable "repo=$repo"
    branch="$(jq -er .default_branch <<<"$metadata")" ||
      fault discovery default-branch-unreadable "repo=$repo"
    encoded_branch="$(jq -rn --arg value "$branch" '$value|@uri')"
    sha="$(gh api "repos/$ORG/$repo/branches/$encoded_branch" 2>/dev/null | jq -er .commit.sha)" ||
      fault discovery default-head-unreadable "repo=$repo branch=$branch"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fault discovery default-head-invalid "repo=$repo branch=$branch"
    printf '%s\t%s\t%s\n' "$repo" "$branch" "$sha"
  done <<<"$repositories" | sort
}

discover_selected_state >"$tmp/selected-before.tsv"
selected="$(cut -f1 "$tmp/selected-before.tsv")"
repo_count="$(wc -l <"$tmp/selected-before.tsv" | tr -d ' ')"
echo "::notice::phase=discovery result=selected ruleset=$ruleset_name repositories=$repo_count"

repos="$(tr '\n' ' ' <<<"$selected" | sed 's/[[:space:]]*$//')"
# `RCA_REQUIRE_VERIFIED=true` because this caller is about to *apply* a rule.
# The selected set comes from the ruleset's own `repository_properties`, not from
# `verjson-stack`, so it can contain a repository whose stack declares no
# required contexts. The audit skips those and still exits 0 — right for the
# org-wide report, wrong here, where a skip means nothing was ever confirmed
# about a repository that is one API call away from being gated.
if ! RCA_ORG="$ORG" RCA_CONTRACT_FILE="$CONTRACT_FILE" RCA_REPOS="$repos" RCA_HEADS_FILE="$tmp/selected-before.tsv" RCA_REQUIRE_VERIFIED=true bash "$AUDIT_SCRIPT"; then
  fault conformance selected-repositories-nonconformant "ruleset=$ruleset_name repositories=$repo_count"
fi
echo "::notice::phase=conformance result=ready ruleset=$ruleset_name repositories=$repo_count"

if [ "$APPLY" = false ]; then
  echo "::notice::phase=done result=read-only-ready ruleset=$ruleset_name"
  exit 0
fi
[ "$ACK" = "$expected_ack" ] || fault authorization acknowledgement-mismatch "set RCA_ACK=$expected_ack"

live_again="$(gh api "orgs/$ORG/rulesets/$ruleset_id" 2>/dev/null)" ||
  fault mutation ruleset-reread-failed "id=$ruleset_id"
mutable_ruleset() { jq -S -c '{name,target,enforcement,bypass_actors,conditions,rules}'; }
live_mutable="$(mutable_ruleset <<<"$live")" || fault mutation live-preimage-invalid "id=$ruleset_id"
live_again_mutable="$(mutable_ruleset <<<"$live_again")" || fault mutation live-reread-invalid "id=$ruleset_id"
[ "$live_mutable" = "$live_again_mutable" ] || fault mutation ruleset-changed-during-audit "id=$ruleset_id"

discover_selected_state >"$tmp/selected-pre-put.tsv"
cmp -s "$tmp/selected-before.tsv" "$tmp/selected-pre-put.tsv" ||
  fault mutation governed-state-changed-during-audit "ruleset=$ruleset_name"

jq --argjson contexts "$planned_contexts" '
  {
    name,
    target,
    enforcement,
    bypass_actors,
    conditions,
    rules: [.rules[] |
      if .type == "required_status_checks" then
        . as $rule |
        .parameters.required_status_checks = [
          $contexts[] as $context |
          (($rule.parameters.required_status_checks |
            map(select(.context == $context)) | first) // {context: $context})
        ]
      else . end
    ]
  }
' <<<"$live" >"$tmp/update.json"
expected_mutable="$(jq -S -c . "$tmp/update.json")"

git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  fault recovery git-directory-unreadable "repo=$repo_root"
recovery_dir="$git_common_dir/ruleset-recovery"
mkdir -p "$recovery_dir"
chmod 700 "$recovery_dir"
recovery_file="$recovery_dir/${ruleset_name}-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
selected_json="$(jq -Rn '[inputs | split("\t") | {repo:.[0],default_branch:.[1],head_sha:.[2]}]' <"$tmp/selected-before.tsv")"
jq -n \
  --arg organization "$ORG" \
  --argjson ruleset_id "$ruleset_id" \
  --arg ruleset_name "$ruleset_name" \
  --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson preimage "$live_mutable" \
  --argjson intended "$expected_mutable" \
  --argjson selected "$selected_json" \
  '{schema_version:1,organization:$organization,ruleset_id:$ruleset_id,ruleset_name:$ruleset_name,captured_at:$captured_at,preimage:$preimage,intended:$intended,selected:$selected}' \
  >"$recovery_file"
chmod 600 "$recovery_file"
echo "::notice::phase=recovery result=preimage-retained path=$recovery_file"

gh api --method PUT "orgs/$ORG/rulesets/$ruleset_id" --input "$tmp/update.json" >/dev/null ||
  fault mutation update-failed "id=$ruleset_id recovery_file=$recovery_file"

updated="$(gh api "orgs/$ORG/rulesets/$ruleset_id" 2>/dev/null)" ||
  fault verification ruleset-unreadable "id=$ruleset_id recovery_file=$recovery_file"
updated_mutable="$(mutable_ruleset <<<"$updated")" ||
  fault verification organization-ruleset-invalid "id=$ruleset_id recovery_file=$recovery_file"
[ "$updated_mutable" = "$expected_mutable" ] ||
  fault verification organization-preimage-delta-mismatch "id=$ruleset_id recovery_file=$recovery_file"

discover_selected_state >"$tmp/selected-after.tsv"
cmp -s "$tmp/selected-before.tsv" "$tmp/selected-after.tsv" ||
  fault verification governed-state-changed-after-update "ruleset=$ruleset_name recovery_file=$recovery_file"

expected_parameters="$(jq -S -c '[.rules[] | select(.type == "required_status_checks")][0].parameters' "$tmp/update.json")"

while IFS=$'\t' read -r repo branch _; do
  [ -n "$repo" ] || continue
  encoded_branch="$(jq -rn --arg value "$branch" '$value|@uri')"
  effective="$(gh api "repos/$ORG/$repo/rules/branches/$encoded_branch" 2>/dev/null)" ||
    fault verification effective-rule-unreadable "repo=$repo recovery_file=$recovery_file"
  jq -e --argjson id "$ruleset_id" --argjson expected "$expected_parameters" '
    [.[] | select(
      .ruleset_id == $id and
      .ruleset_source_type == "Organization" and
      .type == "required_status_checks"
    )] as $rules |
    ($rules | length) == 1 and
    ($rules[0].parameters == $expected)
  ' <<<"$effective" >/dev/null ||
    fault verification effective-rule-mismatch "repo=$repo recovery_file=$recovery_file"
done <"$tmp/selected-after.tsv"

echo "::notice::phase=done result=applied-and-verified ruleset=$ruleset_name repositories=$repo_count recovery_file=$recovery_file"

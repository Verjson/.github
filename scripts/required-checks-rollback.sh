#!/usr/bin/env bash
# Restore the exact preimage retained by required-checks-rollout.sh.
set -euo pipefail

fault() { echo "::error::phase=$1 result=$2 ${3:-}" >&2; exit 2; }
for tool in gh jq cmp readlink stat git; do
  command -v "$tool" >/dev/null 2>&1 || fault startup toolchain-missing "tool=$tool"
done

ORG="${RCA_ORG:?RCA_ORG must name the organization}"
RECOVERY_FILE="${RCA_RECOVERY_FILE:?RCA_RECOVERY_FILE must name the retained preimage artifact}"
ACK="${RCA_ACK:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
contract="$repo_root/.github/required-check-contract.json"

expected_org="$(jq -er '.ruleset_plan.rollout.organization' "$contract")" || fault contract declaration-invalid
ruleset_id="$(jq -er '.ruleset_plan.rollout.ruleset_id' "$contract")" || fault contract declaration-invalid
ruleset_name="$(jq -er '.ruleset_plan.rollout.ruleset_name' "$contract")" || fault contract declaration-invalid
expected_ack="$(jq -er '.ruleset_plan.rollout.rollback_acknowledgement' "$contract")" || fault contract declaration-invalid
[ "$ORG" = "$expected_org" ] || fault authorization organization-mismatch "expected=$expected_org actual=$ORG"
[ "$ACK" = "$expected_ack" ] || fault authorization acknowledgement-mismatch "set RCA_ACK=$expected_ack"

git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  fault recovery git-directory-unreadable
recovery_dir="$(readlink -f "$git_common_dir/ruleset-recovery")"
resolved_file="$(readlink -f "$RECOVERY_FILE")"
case "$resolved_file" in "$recovery_dir"/*) ;; *) fault recovery artifact-outside-protected-directory ;; esac
[ -f "$resolved_file" ] && [ ! -L "$RECOVERY_FILE" ] || fault recovery artifact-not-regular
[ "$(stat -c %a "$resolved_file")" = 600 ] || fault recovery artifact-permissions-invalid "expected=600"
remote_copy="$recovery_dir/.rollback-remote-$$"
rollback_payload="$recovery_dir/.rollback-payload-$$"
trap 'rm -f "$remote_copy" "$rollback_payload"' EXIT

jq -e \
  --arg org "$ORG" --argjson id "$ruleset_id" --arg name "$ruleset_name" '
  .schema_version == 1 and .organization == $org and .ruleset_id == $id and
  .ruleset_name == $name and (.preimage | type == "object") and
  (.intended | type == "object") and (.selected | type == "array")
' "$resolved_file" >/dev/null || fault recovery artifact-invalid

default_branch="$(gh api "repos/$ORG/.github" 2>/dev/null | jq -er .default_branch)" ||
  fault authorization default-branch-unreadable
for binding in \
  ".github/required-check-contract.json:$contract" \
  "scripts/required-checks-rollback.sh:$(readlink -f "$0")"; do
  remote_path="${binding%%:*}"; local_path="${binding#*:}"
  gh api "repos/$ORG/.github/contents/$remote_path?ref=$default_branch" \
    -H 'Accept: application/vnd.github.raw+json' >"$remote_copy" 2>/dev/null ||
    fault authorization canonical-file-unreadable "path=$remote_path"
  cmp -s "$local_path" "$remote_copy" ||
    fault authorization canonical-file-not-on-default "path=$remote_path"
done

mutable_ruleset() { jq -S -c '{name,target,enforcement,bypass_actors,conditions,rules}'; }
live="$(gh api "orgs/$ORG/rulesets/$ruleset_id" 2>/dev/null)" || fault rollback ruleset-unreadable
live_mutable="$(mutable_ruleset <<<"$live")" || fault rollback live-ruleset-invalid
intended="$(jq -S -c .intended "$resolved_file")"
[ "$live_mutable" = "$intended" ] || fault rollback live-state-does-not-match-artifact

jq -S '.preimage' "$resolved_file" >"$rollback_payload"
gh api --method PUT "orgs/$ORG/rulesets/$ruleset_id" --input "$rollback_payload" >/dev/null ||
  fault rollback update-failed "artifact=$resolved_file"
restored="$(gh api "orgs/$ORG/rulesets/$ruleset_id" 2>/dev/null)" ||
  fault verification ruleset-unreadable "artifact=$resolved_file"
restored_mutable="$(mutable_ruleset <<<"$restored")" || fault verification ruleset-invalid
preimage="$(jq -S -c .preimage "$resolved_file")"
[ "$restored_mutable" = "$preimage" ] || fault verification preimage-mismatch "artifact=$resolved_file"
echo "::notice::phase=done result=rolled-back-and-verified ruleset=$ruleset_name artifact=$resolved_file"

#!/usr/bin/env bash
set -euo pipefail

readonly ORG="${PRIVILEGED_MERGE_ORG:-Verjson}"
readonly SECRET_NAME="${PRIVILEGED_MERGE_SECRET_NAME:-ORG_ADMIN_TOKEN}"
readonly CALLER_PATH=".github/workflows/ai-privileged-merge.yml"
readonly GENERATOR="scripts/gen-privileged-merge-caller.sh"
readonly CANONICAL_REPOSITORY="$ORG/.github"
readonly AUDIT_SHA="${PRIVILEGED_MERGE_AUDIT_SHA:-}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LOCAL_CANONICAL_WORKFLOW="$REPO_ROOT/$CALLER_PATH"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ ! "$AUDIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error title=Invalid privileged merge audit SHA::PRIVILEGED_MERGE_AUDIT_SHA must be a canonical lowercase 40-character commit SHA."
  exit 1
fi
if [ ! -r "$LOCAL_CANONICAL_WORKFLOW" ]; then
  echo "::error title=Missing local canonical privileged merge workflow::path=$CALLER_PATH"
  exit 1
fi
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error title=Missing ORG_ADMIN_TOKEN::Fleet conformance cannot verify privileged merge callers or organization-secret access."
  exit 1
fi
command -v gh >/dev/null 2>&1 || {
  echo "::error title=Missing gh::Fleet conformance requires the GitHub CLI."
  exit 1
}
command -v base64 >/dev/null 2>&1 || {
  echo "::error title=Missing base64::Fleet conformance requires base64 to inspect caller content."
  exit 1
}
visibility="$(
  gh api "orgs/$ORG/actions/secrets/$SECRET_NAME" --jq .visibility
)" || {
  echo "::error title=Unreadable organization secret::Cannot verify $SECRET_NAME visibility for $ORG."
  exit 1
}
case "$visibility" in
  all|private|selected) ;;
  *)
    echo "::error title=Invalid organization secret visibility::$SECRET_NAME returned unsupported visibility '$visibility'."
    exit 1
    ;;
esac

if [ -n "${VERJSON_MANAGED_REPOSITORIES:-}" ]; then
  repositories="$VERJSON_MANAGED_REPOSITORIES"
else
  repositories="$(
    gh api --paginate "orgs/$ORG/repos?type=all&per_page=100" \
      --jq '.[] | select((.archived or .fork or .is_template) | not) | .full_name'
  )" || {
    echo "::error title=Unreadable repository fleet::Cannot enumerate active $ORG repositories."
    exit 1
  }
fi

declare -A selected_repositories=()
if [ "$visibility" = selected ]; then
  selected="$(
    gh api --paginate "orgs/$ORG/actions/secrets/$SECRET_NAME/repositories" \
      --jq '.repositories[].full_name'
  )" || {
    echo "::error title=Unreadable organization secret access::Cannot enumerate repositories selected for $SECRET_NAME."
    exit 1
  }
  while IFS= read -r repository; do
    [ -n "$repository" ] && selected_repositories["$repository"]=1
  done <<<"$selected"
fi

failures=0
repositories_scanned=0
consumers=0
while IFS= read -r repository; do
  [ -n "$repository" ] || continue
  repositories_scanned=$((repositories_scanned + 1))
  metadata="$(gh api "repos/$repository" --jq '[.default_branch,.visibility] | @tsv')" || {
    echo "::error title=Unreadable repository metadata::repository=$repository"
    failures=$((failures + 1))
    continue
  }
  IFS=$'\t' read -r default_branch visibility_type <<<"$metadata"
  if [ -z "$default_branch" ] || [ -z "$visibility_type" ]; then
    echo "::error title=Invalid repository metadata::repository=$repository"
    failures=$((failures + 1))
    continue
  fi

  direct_consumer=false
  content_ref="$default_branch"
  if [ "$repository" = "$CANONICAL_REPOSITORY" ]; then
    direct_consumer=true
    content_ref="$AUDIT_SHA"
    consumers=$((consumers + 1))
  fi

  caller_response=""
  caller_error=""
  caller_available=false
  caller_file="$tmp/caller-$repositories_scanned.yml"
  if ! caller_response="$(gh api "repos/$repository/contents/$CALLER_PATH?ref=$content_ref" \
    --jq .content 2>&1)"; then
    caller_error="$caller_response"
    if grep -q 'HTTP 404' <<<"$caller_error"; then
      if [ "$direct_consumer" = true ]; then
        echo "::error title=Missing canonical privileged merge workflow::repository=$repository path=$CALLER_PATH audit_sha=$AUDIT_SHA"
        failures=$((failures + 1))
      else
        # Secret visibility is not consumer registration: this credential is
        # organization-wide, while only repositories with a caller can invoke
        # the reusable terminal workflow.
        continue
      fi
    else
      if [ "$direct_consumer" = true ]; then
        echo "::error title=Unreadable canonical privileged merge workflow::repository=$repository path=$CALLER_PATH audit_sha=$AUDIT_SHA"
      else
        echo "::error title=Unreadable privileged merge caller::repository=$repository path=$CALLER_PATH"
      fi
      failures=$((failures + 1))
      [ "$direct_consumer" = true ] || continue
    fi
  elif ! printf '%s' "$caller_response" | base64 --decode >"$caller_file" 2>/dev/null; then
    if [ "$direct_consumer" = true ]; then
      echo "::error title=Unreadable canonical privileged merge workflow::repository=$repository path=$CALLER_PATH reason='invalid base64 content'"
    else
      echo "::error title=Unreadable privileged merge caller::repository=$repository path=$CALLER_PATH reason='invalid base64 content'"
    fi
    failures=$((failures + 1))
    [ "$direct_consumer" = true ] || continue
  else
    caller_available=true
    caller_content="$(<"$caller_file")"
  fi

  if [ "$direct_consumer" = true ]; then
    if [ "$caller_available" = true ] && ! cmp -s "$LOCAL_CANONICAL_WORKFLOW" "$caller_file"; then
      echo "::error title=Mismatched canonical privileged merge workflow::repository=$repository path=$CALLER_PATH audit_sha=$AUDIT_SHA reason='remote bytes differ from the checked-out audit revision'"
      failures=$((failures + 1))
    fi
  elif [ "$caller_available" = true ]; then
    consumers=$((consumers + 1))
    mapfile -t caller_pins < <(
      sed -nE 's#^[[:space:]]+uses: Verjson/\.github/\.github/workflows/ai-privileged-merge\.yml@([0-9a-f]{40})[[:space:]]*$#\1#p' \
        <<<"$caller_content"
    )
    if [ "${#caller_pins[@]}" -ne 1 ]; then
      echo "::error title=Invalid privileged merge caller pin::repository=$repository path=$CALLER_PATH reason='expected exactly one immutable canonical workflow pin'"
      failures=$((failures + 1))
    else
      caller_contract_sha="${caller_pins[0]}"
      relation="$(gh api "repos/$CANONICAL_REPOSITORY/compare/$caller_contract_sha...main" --jq .status)" || {
        echo "::error title=Untrusted privileged merge caller pin::repository=$repository contract_sha=$caller_contract_sha reason='pin is absent from canonical main history'"
        failures=$((failures + 1))
        relation=""
      }
      case "$relation" in
        ahead|identical) ;;
        "") ;;
        *)
          echo "::error title=Untrusted privileged merge caller pin::repository=$repository contract_sha=$caller_contract_sha relation=$relation reason='pin is not reachable from canonical main'"
          failures=$((failures + 1))
          relation=""
          ;;
      esac

      historical_generator=""
      historical_workflow=""
      if [ -n "$relation" ]; then
        if ! generator_response="$(gh api "repos/$CANONICAL_REPOSITORY/contents/$GENERATOR?ref=$caller_contract_sha" --jq .content)" ||
          ! historical_generator="$(printf '%s' "$generator_response" | base64 --decode 2>/dev/null)"; then
          echo "::error title=Unreadable historical caller generator::repository=$repository contract_sha=$caller_contract_sha"
          failures=$((failures + 1))
        fi
        if ! workflow_response="$(gh api "repos/$CANONICAL_REPOSITORY/contents/$CALLER_PATH?ref=$caller_contract_sha" --jq .content)" ||
          ! historical_workflow="$(printf '%s' "$workflow_response" | base64 --decode 2>/dev/null)"; then
          echo "::error title=Unreadable historical privileged workflow::repository=$repository contract_sha=$caller_contract_sha"
          failures=$((failures + 1))
        fi
      fi

      workflow_call_block="$(awk '
        $0 == "  workflow_call:" { capture=1 }
        capture && /^[^ ]/ { exit }
        capture { print }
      ' <<<"$historical_workflow")"
      if [ -n "$relation" ] && {
        [ -z "$historical_generator" ] ||
        ! grep -q '^      privileged_lane:$' <<<"$workflow_call_block" ||
        ! grep -q '^  privileged_merge:$' <<<"$historical_workflow";
      }; then
        echo "::error title=Incompatible privileged merge contract::repository=$repository contract_sha=$caller_contract_sha reason='historical generator or reusable interface is incomplete'"
        failures=$((failures + 1))
      elif [ -n "$relation" ] && [ -n "$historical_generator" ]; then
        printf '%s\n' "$historical_generator" >"$tmp/historical-generator.sh"
        canonical_caller="$(env -u GH_TOKEN bash "$tmp/historical-generator.sh" "$caller_contract_sha")" || {
          echo "::error title=Caller generation failed::repository=$repository contract_sha=$caller_contract_sha"
          failures=$((failures + 1))
          canonical_caller=""
        }
        if [ -n "$canonical_caller" ] && [ "$caller_content" != "$canonical_caller" ]; then
          echo "::error title=Non-canonical privileged merge caller::repository=$repository path=$CALLER_PATH remediation='scripts/gen-privileged-merge-caller.sh $caller_contract_sha > $CALLER_PATH'"
          failures=$((failures + 1))
        fi
      fi
    fi
  fi
  unset caller_response caller_content caller_error caller_pins caller_contract_sha canonical_caller \
    caller_available caller_file content_ref direct_consumer relation historical_generator \
    historical_workflow generator_response workflow_response workflow_call_block

  has_secret=false
  case "$visibility" in
    all) has_secret=true ;;
    private)
      [ "$visibility_type" = private ] && has_secret=true
      ;;
    selected)
      [ "${selected_repositories[$repository]:-}" = 1 ] && has_secret=true
      ;;
  esac
  if [ "$has_secret" != true ]; then
    echo "::error title=Missing ORG_ADMIN_TOKEN access::repository=$repository secret=$SECRET_NAME remediation='grant repository access to the organization secret'"
    failures=$((failures + 1))
  fi
done <<<"$repositories"

if [ "$repositories_scanned" -eq 0 ]; then
  echo "::error title=Empty managed fleet::No active $ORG repositories were available for conformance verification."
  exit 1
fi
if [ "$consumers" -eq 0 ]; then
  echo "::error title=Empty privileged consumer inventory::No direct or generated privileged merge consumers were found across $repositories_scanned active repositories."
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  echo "result=nonconformant repositories_scanned=$repositories_scanned consumers=$consumers failures=$failures"
  exit 1
fi

echo "result=conformant repositories_scanned=$repositories_scanned consumers=$consumers"

#!/usr/bin/env bash
set -euo pipefail

readonly ORG="${PRIVILEGED_MERGE_ORG:-Verjson}"
readonly SECRET_NAME="${PRIVILEGED_MERGE_SECRET_NAME:-ORG_ADMIN_TOKEN}"
readonly CALLER_PATH=".github/workflows/ai-privileged-merge.yml"
readonly GENERATOR="scripts/gen-privileged-merge-caller.sh"

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
[ -f "$GENERATOR" ] || {
  echo "::error title=Missing caller generator::Fleet conformance cannot load $GENERATOR."
  exit 1
}
canonical_caller="$(bash "$GENERATOR")" || {
  echo "::error title=Caller generation failed::Fleet conformance cannot establish canonical caller content."
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
count=0
while IFS= read -r repository; do
  [ -n "$repository" ] || continue
  count=$((count + 1))
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

  caller_response=""
  caller_error=""
  if ! caller_response="$(gh api "repos/$repository/contents/$CALLER_PATH?ref=$default_branch" \
    --jq .content 2>&1)"; then
    caller_error="$caller_response"
    if grep -q 'HTTP 404' <<<"$caller_error"; then
      echo "::error title=Missing privileged merge caller::repository=$repository path=$CALLER_PATH remediation='scripts/gen-privileged-merge-caller.sh > $CALLER_PATH'"
    else
      echo "::error title=Unreadable privileged merge caller::repository=$repository path=$CALLER_PATH"
    fi
    failures=$((failures + 1))
  elif ! caller_content="$(printf '%s' "$caller_response" | base64 --decode 2>/dev/null)"; then
    echo "::error title=Unreadable privileged merge caller::repository=$repository path=$CALLER_PATH reason='invalid base64 content'"
    failures=$((failures + 1))
  elif [ "$caller_content" != "$canonical_caller" ]; then
    echo "::error title=Non-canonical privileged merge caller::repository=$repository path=$CALLER_PATH remediation='scripts/gen-privileged-merge-caller.sh > $CALLER_PATH'"
    failures=$((failures + 1))
  fi
  unset caller_response caller_content caller_error

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

if [ "$count" -eq 0 ]; then
  echo "::error title=Empty managed fleet::No active $ORG repositories were available for conformance verification."
  exit 1
fi
if [ "$failures" -ne 0 ]; then
  echo "result=nonconformant repositories=$count failures=$failures"
  exit 1
fi

echo "result=conformant repositories=$count"

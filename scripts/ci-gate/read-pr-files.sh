#!/usr/bin/env bash
set -uo pipefail

repo="${1:-}"
pr_number="${2:-}"
max_attempts=4

[ -n "$repo" ] && [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::phase=preflight input=pr-files status=invalid-request" >&2
  exit 2
}

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  if files="$(
    gh api "repos/$repo/pulls/$pr_number/files" --paginate --jq '.[]' 2>/dev/null |
      jq -cs '
        if all(.[]; type == "object" and (.filename | type == "string" and length > 0))
        then .
        else error("invalid PR files response")
        end
      ' 2>/dev/null
  )"; then
    if [ "$attempt" -gt 1 ]; then
      echo "::notice::phase=preflight input=pr-files status=recovered attempt=$attempt/$max_attempts" >&2
    fi
    printf '%s\n' "$files"
    exit 0
  fi

  if [ "$attempt" -lt "$max_attempts" ]; then
    echo "::notice::phase=preflight input=pr-files status=retry attempt=$attempt/$max_attempts" >&2
  fi
done

echo "::error::phase=preflight input=pr-files status=infrastructure_unavailable attempts=$max_attempts; no review pass reserved" >&2
exit 1

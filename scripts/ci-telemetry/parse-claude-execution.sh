#!/usr/bin/env bash
set -euo pipefail

execution_file="${1:-}"

missing_payload() {
  jq -n \
    --arg execution_file "${execution_file}" \
    '{
      execution_file,
      execution_file_present: false,
      execution_file_parse_ok: false,
      result_found: false,
      duration_ms: null,
      num_turns: null,
      total_cost_usd: null,
      is_error: null,
      subtype: null
    }'
}

if [ -z "$execution_file" ] || [ ! -f "$execution_file" ]; then
  missing_payload
  exit 0
fi

if ! jq -e . "$execution_file" >/dev/null 2>&1; then
  jq -n \
    --arg execution_file "$execution_file" \
    '{
      execution_file,
      execution_file_present: true,
      execution_file_parse_ok: false,
      result_found: false,
      duration_ms: null,
      num_turns: null,
      total_cost_usd: null,
      is_error: null,
      subtype: null
    }'
  exit 0
fi

jq -c --arg execution_file "$execution_file" '
  def candidate_messages:
    if type == "array" then
      [.[] | objects]
    elif type == "object" then
      [.]
    else
      []
    end;

  (candidate_messages | map(select((.type // "") == "result")) | last) as $result
  | if $result == null then
      {
        execution_file: $execution_file,
        execution_file_present: true,
        execution_file_parse_ok: true,
        result_found: false,
        duration_ms: null,
        num_turns: null,
        total_cost_usd: null,
        is_error: null,
        subtype: null
      }
    else
      {
        execution_file: $execution_file,
        execution_file_present: true,
        execution_file_parse_ok: true,
        result_found: true,
        duration_ms: ($result.duration_ms // null),
        num_turns: ($result.num_turns // null),
        total_cost_usd: ($result.total_cost_usd // null),
        is_error: ($result.is_error // null),
        subtype: ($result.subtype // null)
      }
    end
' "$execution_file"

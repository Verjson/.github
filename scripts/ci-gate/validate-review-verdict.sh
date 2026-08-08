#!/usr/bin/env bash
set -euo pipefail

verdict=${1:-}
sensitive=${2:-false}

jq -e --argjson sensitive "$sensitive" '
  def text: type == "string" and test("\\S");
  def location: text and test("^.+:[1-9][0-9]*$");
  type == "object"
  and (.blocking | type == "boolean")
  and (.summary | text)
  and (.review_first | type == "array")
  and (all(.review_first[]; (.location | location) and (.why | text)))
  and (($sensitive | not) or (.review_first | length > 0))
  and (.findings | type == "array")
  and (all(.findings[];
    (.location | location)
    and (.reason | text)
    and (.failure_scenario | text)))
  and ((.blocking | not) or (.findings | length > 0))
  and (.followups | type == "array")
' <<<"$verdict" >/dev/null

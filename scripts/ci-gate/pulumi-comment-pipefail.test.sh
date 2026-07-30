#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/pulumi-ci.yml"

awk '
  /^  preview-admission:$/ {
    for (i = 0; i < 20000; i++) {
      print "    # padding proves early matches remain true under pipefail"
    }
  }
  { print }
' "$repo_root/.github/workflows/pulumi-ci.yml" >"$fixture"

output="$(
  PULUMI_CI_WORKFLOW="$fixture" \
    bash "$here/pulumi-comment.test.sh"
)"

grep -qF 'All tests passed.' <<<"$output"
printf 'ok   - large extracted jobs do not turn early grep matches into pipefail failures\n'

#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/ai-review-merge.yml"
validator="$root/scripts/ci-gate/review-verdict.py"
validator_invocation="python3 \"\$RUNNER_TEMP/review-verdict.py\""
legacy_normalizer="normalized=\"\$(jq -c"

grep -qF 'scripts/ci-gate/review-verdict.py' "$workflow"
[ "$(grep -cF "$validator_invocation" "$workflow")" -eq 2 ]
[ "$(grep -cF 'REVIEW_PASS: "1"' "$workflow")" -eq 1 ]
[ "$(grep -cF 'REVIEW_PASS: "2"' "$workflow")" -eq 1 ]
if grep -q 'if jq -e --argjson sensitive' "$workflow"; then exit 1; fi
if grep -qF "$legacy_normalizer" "$workflow"; then exit 1; fi

grep -qF 'Every review_first.location MUST contain exactly one file and one' "$workflow"
grep -qF 'no ranges or comma-separated locations.' "$workflow"

python3 -m py_compile "$validator"

echo "Canonical semantic verdict contract: ok"

#!/usr/bin/env bash
# Generate a consumer's thin gate re-arm caller.
#
# Usage:
#   scripts/gen-gate-rearm-caller.sh <verjson-github-contract-sha> \
#     > .github/workflows/gate-rearm.yml
#
# The SHA is required because this pull_request_target workflow carries
# actions:write. A mutable ref would let a later upstream change alter privileged
# behavior in every adopter without a consumer-side review.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: gen-gate-rearm-caller.sh <40-character-contract-sha>" >&2
  exit 2
fi

contract_sha="$1"
[[ "$contract_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo "contract SHA must be exactly 40 lowercase hexadecimal characters" >&2
  exit 2
}

readonly TARGET="Verjson/.github/.github/workflows/gate-rearm.yml@$contract_sha"

emit() {
  cat <<YAML
# GENERATED FILE — do not edit by hand.
# Regenerate with:
#   scripts/gen-gate-rearm-caller.sh $contract_sha > .github/workflows/gate-rearm.yml
#
# Thin caller for the immutable gate re-arm bridge in Verjson/.github.
name: gate re-arm

on:
  pull_request_target:
    types: [opened, reopened, synchronize, ready_for_review, converted_to_draft, edited, unlabeled, labeled]

permissions:
  contents: read

jobs:
  rearm:
    permissions:
      contents: read
      actions: write
      pull-requests: write
    uses: $TARGET
    secrets:
      AI_REVIEW_APP_PRIVATE_KEY: \${{ secrets.AI_REVIEW_APP_PRIVATE_KEY }}
YAML
}

out="$(emit)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  printf '%s\n' "$out" |
    python3 -c 'import sys, yaml; yaml.load(sys.stdin, Loader=yaml.BaseLoader)' 2>/dev/null ||
    { echo "internal error: generated caller is not valid YAML; refusing to emit" >&2; exit 3; }
fi
printf '%s\n' "$out"

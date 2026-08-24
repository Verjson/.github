#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: gen-ai-review-label-rearm-caller.sh <40-character-contract-sha>" >&2; exit 2; }
contract_sha="$1"
[[ "$contract_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "contract SHA must be exactly 40 lowercase hexadecimal characters" >&2; exit 2; }

cat <<YAML
# GENERATED FILE — do not edit by hand.
# Regenerate with:
#   scripts/gen-ai-review-label-rearm-caller.sh $contract_sha > .github/workflows/ai-review-label-rearm.yml
name: AI review explicit label re-arm

on:
  pull_request_target:
    types: [labeled]

permissions:
  contents: read

jobs:
  rearm:
    permissions:
      actions: write
      contents: read
      issues: write
      pull-requests: write
    uses: Verjson/.github/.github/workflows/gate-rearm.yml@$contract_sha
    secrets:
      AI_REVIEW_APP_PRIVATE_KEY: \${{ secrets.AI_REVIEW_APP_PRIVATE_KEY }}
YAML

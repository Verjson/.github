#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] && [ "$1" = --local ] || {
  echo "usage: gen-ai-review-lifecycle-rearm-caller.sh --local" >&2
  exit 2
}

cat <<'YAML'
# GENERATED FILE — do not edit by hand.
# Regenerate with:
# scripts/gen-ai-review-lifecycle-rearm-caller.sh --local > .github/workflows/ai-review-lifecycle-rearm.yml
name: AI review lifecycle re-arm

on:
  pull_request_target:
    types: [ready_for_review, converted_to_draft, edited, unlabeled]

permissions:
  actions: read
  contents: read

jobs:
  rearm:
    permissions:
      actions: write
      checks: write
      contents: read
      issues: write
      pull-requests: write
    uses: ./.github/workflows/gate-rearm.yml
    secrets: inherit
    with:
      ai_review_environment: ai-review-app
YAML

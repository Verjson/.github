#!/usr/bin/env bash
# Generate a consumer's thin `ai-privileged-merge.yml` caller.
#
# The caller is generated rather than hand-written because two of its details
# are contractual and fail SILENTLY when wrong:
#
#   1. The job key MUST be `privileged_merge`. A reusable call publishes its
#      check as "<caller job> / <callee job>", and ai-review-merge.yml excludes
#      exactly "privileged_merge / privileged_merge". A consumer who writes
#      `merge:` produces "merge / privileged_merge", which the gate then counts
#      as one of its own required checks and waits on forever — while that check
#      is itself waiting for the gate.
#   2. The ref MUST be @main, not a SHA. See the comment in the emitted file.
#
# Usage: gen-privileged-merge-caller.sh '<runner-labels-json>' [ref]
#   gen-privileged-merge-caller.sh '["ubuntu-24.04"]' > .github/workflows/ai-privileged-merge.yml
set -euo pipefail

runner_labels="${1:?usage: gen-privileged-merge-caller.sh '<runner-labels-json>' [ref]}"
ref="${2:-main}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' \
  <<<"$runner_labels" >/dev/null 2>&1 \
  || { echo "runner_labels must be a non-empty JSON array of strings, got: $runner_labels" >&2; exit 2; }

cat <<YAML
# GENERATED FILE — do not edit by hand.
# Regenerate with:
#   scripts/gen-privileged-merge-caller.sh '$runner_labels' > .github/workflows/ai-privileged-merge.yml
#
# Thin caller for the canonical privileged merge (Verjson/.github). All trust
# logic lives in the canonical workflow; nothing here may re-implement it.
name: AI privileged merge

on:
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize, labeled, unlabeled]
  workflow_dispatch:
    inputs:
      pr_number:
        required: true
        type: string
      expected_head_sha:
        required: true
        type: string
      source_run_id:
        required: true
        type: string

permissions:
  contents: read

# Deliberately NOT the canonical workflow's group name. A called workflow's
# concurrency is evaluated in the caller's context, so an identical group would
# put the reusable's job behind the caller job that invoked it. Keyed by event
# as well as PR so the dispatched continuation cannot cancel the
# pull_request_target check and leave a red mark on a merged PR (ADR 0039).
concurrency:
  group: ai-privileged-merge-call-\${{ github.event.pull_request.number || inputs.pr_number }}-\${{ github.event_name }}
  cancel-in-progress: true

jobs:
  # The job key \`privileged_merge\` is CONTRACTUAL — see the generator header.
  # Renaming it deadlocks the gate silently.
  privileged_merge:
    # Pinned to @main, not a SHA, and this is a deliberate exception to the
    # organization's pin policy. The canonical workflow already anchors trust to
    # Verjson/.github@main at runtime, so a SHA-pinned caller would let a
    # repository admin freeze an older gate while the trust anchor moved on —
    # the exact divergence this split exists to remove.
    uses: Verjson/.github/.github/workflows/ai-privileged-merge.yml@$ref
    secrets: inherit
    with:
      pr_number: \${{ github.event.pull_request.number || inputs.pr_number }}
      expected_head_sha: \${{ github.event.pull_request.head.sha || inputs.expected_head_sha }}
      source_run_id: \${{ inputs.source_run_id }}
      runner_labels: '$runner_labels'
YAML
